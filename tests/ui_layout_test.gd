extends Node
## Headless layout test: every menu screen / overlay must fit the base
## viewport (1152x648, project.godot's default with canvas_items/expand), and
## a wider one. Each screen is instantiated in a SubViewport of that size;
## after the containers sort, every visible Control's global rect must lie
## inside the viewport. Children of ScrollContainers are skipped (clipping
## there is intended); the ScrollContainer itself is checked.
##   godot --headless res://tests/ui_layout_test.tscn

const SIZES: Array[Vector2i] = [Vector2i(1152, 648), Vector2i(1600, 648)]
## A realistic long SDL pad name, to check device labels clip.
const LONG_PAD_NAME := "PS5 DualSense Wireless Controller (Bluetooth, Extended Report Mode)"
const TOLERANCE := 1.0
## Online co-op: fake remote peers and a profile name of Tuning.net.name_max_len.
const REMOTE_PEERS: Array[int] = [7, 8, 9]
const LONG_PLAYER_NAME := "Supercalifragili"

var _fails := 0
var _vp: SubViewport


func _ready() -> void:
	for s in SIZES:
		_vp = SubViewport.new()
		_vp.size = s
		_vp.gui_disable_input = true
		add_child(_vp)
		await _run_all(str(s))
		_vp.queue_free()
		await frames(2)
	print("UI_LAYOUT %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _run_all(tag: String) -> void:
	await _check_scene(Game.SCENE_MAIN_MENU, "main menu " + tag)
	await _check_how_to_play(tag)
	await _check_scene(Game.SCENE_CONTROLS, "controls screen (pad) " + tag)
	await _check_controls_keyboard(tag)
	await _check_controls_overlay(tag)
	for m in [MatchConfig.Mode.LOCAL_VERSUS, MatchConfig.Mode.VERSUS_CPU, MatchConfig.Mode.COOP]:
		await _check_join(m, tag)
	await _check_results(tag)
	await _check_online_coop_lobby(tag)
	await _check_online_coop_results(tag)
	await _check_pause_menu(tag)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Out-of-bounds visible controls under `root` (outside any ScrollContainer).
func overflows(root: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	var bounds := Rect2(Vector2.ZERO, Vector2(_vp.size)).grow(TOLERANCE)
	_collect(root, bounds, out)
	return out


func _collect(n: Node, bounds: Rect2, out: PackedStringArray) -> void:
	if n is Control:
		var c := n as Control
		if not c.is_visible_in_tree():
			return
		var r := c.get_global_rect()
		if not bounds.encloses(r):
			var desc := "%s(%s) rect=%s" % [c.get_class(), c.name, r]
			if c is Label or c is Button:
				desc += " text=%s" % c.get("text").c_escape().left(40)
			out.append(desc)
		if c is ScrollContainer:
			return
	elif n is CanvasItem and not (n as CanvasItem).visible:
		return
	elif n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	for child in n.get_children():
		_collect(child, bounds, out)


## Visible labels under `root` whose text is cut by their overrun behaviour
## (ellipsis), ignoring labels showing `except`.
func truncated(root: Node, except: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for n in root.find_children("*", "Label", true, false):
		var l := n as Label
		if not l.is_visible_in_tree() or l.text == except or l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING \
				or l.autowrap_mode != TextServer.AUTOWRAP_OFF:
			continue
		var font := l.get_theme_font("font")
		var fs := l.get_theme_font_size("font_size")
		for line in l.text.split("\n"):
			if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > l.size.x + TOLERANCE:
				out.append("%s (width %.0f)" % [line, l.size.x])
	return out


func _assert_fits(root: Node, what: String) -> void:
	await frames(3)
	var bad := overflows(root)
	check(bad.is_empty(), "%s fits the viewport" % what)
	for b in bad.slice(0, 6):
		print("    overflow: ", b)


func _check_scene(path: String, what: String) -> void:
	var n := (load(path) as PackedScene).instantiate()
	_vp.add_child(n)
	await _assert_fits(n, what)
	n.queue_free()
	await frames(1)


func _check_how_to_play(tag: String) -> void:
	var h := HowToPlayPanel.new()
	_vp.add_child(h)
	await _assert_fits(h, "how-to-play overlay " + tag)
	var scroll := _find(h, func(c: Node) -> bool: return c is ScrollContainer) as ScrollContainer
	check(scroll != null, "how-to-play controls list is in a ScrollContainer " + tag)
	if scroll != null:
		var bar := scroll.get_v_scroll_bar()
		var can_scroll := bar.max_value - bar.page > 1.0
		# The list uses the free height: all of it, or at least half the screen.
		check(scroll.size.y >= minf(bar.max_value, _vp.size.y * 0.5) - TOLERANCE,
				"how-to-play list gets a usable height (%.0f of %.0f) %s" % [scroll.size.y, bar.max_value, tag])
		if can_scroll:
			var before := scroll.scroll_vertical
			h.call("scroll_by", 1)
			await frames(2)
			check(scroll.scroll_vertical > before, "how-to-play scrolls down from the pad/keyboard " + tag)
	h.queue_free()
	await frames(1)


func _check_controls_keyboard(tag: String) -> void:
	var cs := (load(Game.SCENE_CONTROLS) as PackedScene).instantiate() as ControlsScreen
	cs.kind = Bindings.Kind.KEYBOARD
	cs.slot = 1
	_vp.add_child(cs)
	await _assert_fits(cs, "controls screen (keyboard P2) " + tag)
	# Longest status line (rebind prompt).
	cs.begin_listen("DODGE_RIGHT")
	await _assert_fits(cs, "controls screen while listening " + tag)
	cs.cancel_listen()
	cs.queue_free()
	await frames(1)


func _check_controls_overlay(tag: String) -> void:
	var cs := ControlsScreen.open_overlay(_vp)
	await _assert_fits(cs.get_parent(), "controls overlay " + tag)
	cs.get_parent().queue_free()
	await frames(1)


func _check_join(m: MatchConfig.Mode, tag: String) -> void:
	var names := {MatchConfig.Mode.LOCAL_VERSUS: "versus", MatchConfig.Mode.VERSUS_CPU: "vs CPU",
			MatchConfig.Mode.COOP: "co-op"}
	var what := "lobby %s " % names[m]
	LobbyModel._memory = {}
	LobbyModel._coop_memory = {}
	Lobby.pending_mode = m
	var j := (load(Game.SCENE_LOBBY) as PackedScene).instantiate() as Lobby
	j.auto_start = false
	_vp.add_child(j)
	await _assert_fits(j, what + "(nobody joined) " + tag)
	j.join(Bindings.Kind.PAD, 0)
	j.join(Bindings.Kind.PAD, 1)
	# Widest values: longest fighter name everywhere, longest level name.
	var longest := _longest_character()
	var low_level := 0
	for s in j.slots:
		s.char_index = longest
		s.cpu_level = low_level
	j.model.coop_enemy_level = low_level
	j.model.coop_ally_level = low_level
	j.model.coop_ally_char = longest
	if m == MatchConfig.Mode.COOP:
		# Every row shown (Waves + ally rows), both cursors on the same row.
		j.model.coop_structure = CoopConfig.Structure.WAVES
		j.model.coop_ally = true
		j.model.coop_roster = longest + 1
		for s in j.slots:
			s.cursor = Lobby.Row.ENEMY_COUNT
	elif m == MatchConfig.Mode.LOCAL_VERSUS:
		for s in j.slots:
			s.cursor = Lobby.Row.ROUNDS
	j._refresh()
	for ui: Dictionary in j._ui:
		if j.slots[j._ui.find(ui)].type == Lobby.SlotType.HUMAN:
			(ui["device"] as Label).text = LONG_PAD_NAME
	await _assert_fits(j, what + "(2 pads joined) " + tag)
	var cut := truncated(j, LONG_PAD_NAME)
	check(cut.is_empty(), what + "shows every row / name untrimmed " + tag)
	for c in cut.slice(0, 6):
		print("    trimmed: ", c)
	if m == MatchConfig.Mode.COOP:
		var scroll := j._settings_scroll
		check(scroll != null, what + "settings rows are in a ScrollContainer " + tag)
		if scroll != null:
			# Walking the cursor to the last row keeps that row in view.
			j.slots[0].cursor = Lobby.Row.CHARACTER
			for i in j.rows().size() - 1:
				j._command(0, Lobby.Cmd.DOWN)
			await frames(3)
			var last: Label = j._row_labels[Lobby.Row.TIMER]
			var view := scroll.get_global_rect().grow(TOLERANCE)
			check(j.slots[0].cursor == Lobby.Row.TIMER and view.encloses(last.get_global_rect()),
					what + "settings list follows the cursor to the last row " + tag)
	LobbyModel._memory = {}
	LobbyModel._coop_memory = {}
	Lobby.pending_mode = MatchConfig.Mode.LOCAL_VERSUS
	j.queue_free()
	await frames(1)


func _check_pause_menu(tag: String) -> void:
	var p := PauseMenu.new()
	_vp.add_child(p)
	p.call("_build")
	p.visible = true
	await _assert_fits(p, "pause menu " + tag)
	p.queue_free()
	await frames(1)


## Results screen: a versus result, and a co-op Waves run with three team-0
## players (P1, P2, CPU ally) and their stats table.
func _check_results(tag: String) -> void:
	var saved := Game.last_result
	var vs := MatchConfig.from_defaults(MatchConfig.Mode.LOCAL_VERSUS)
	var coop := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	coop.coop = CoopConfig.new()
	coop.coop.structure = CoopConfig.Structure.WAVES
	for i in 3:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = MenuHelpers.character_ids()[0]
		if i == 2:
			p.input_kind = PlayerSlotConfig.InputKind.CPU
		coop.players.append(p)
		if i < 2:
			vs.players.append(p)
	var stats := {}
	for i in 3:
		stats[i] = {RunStats.KOS: 12, RunStats.DAMAGE: 4321.0, RunStats.BEST_COMBO: 23,
				RunStats.REVIVES: 3, RunStats.PERFECT_DODGES: 17}
	var results: Array[Dictionary] = [
		{"winner_slot": 0, "wins": PackedInt32Array([2, 1]), "config": vs},
		{"winner_slot": 0, "wins": PackedInt32Array([1, 0]), "config": coop, "stats": stats,
				"run": {"cleared": true, "frames": 7380, "seconds": 123.0, "waves_cleared": 3}},
	]
	for res in results:
		Game.last_result = res
		var r := (load(Game.SCENE_RESULTS) as PackedScene).instantiate()
		_vp.add_child(r)
		await frames(3)
		await _assert_fits(r, "results screen (%s) %s" % ["co-op" if res.has("stats") else "versus", tag])
		r.queue_free()
		await frames(1)
	Game.last_result = saved


## Online co-op lobby (hosted over a LoopbackNetwork): four compact slots,
## the local host, remote players, the CPU ally's place and empty slots;
## per-slot colours and the co-op status line.
func _check_online_coop_lobby(tag: String) -> void:
	var what := "online co-op lobby "
	var u := UiTheme.tuning()
	var net := LoopbackNetwork.new(1)
	Net.start_host(net.create_host())
	var m := Net.room.model
	m.set_mode(MatchConfig.Mode.COOP)
	var j := (load(Game.SCENE_LOBBY) as PackedScene).instantiate() as Lobby
	j.auto_start = false
	_vp.add_child(j)
	check(j._ui.size() == mini(Tuning.net.max_humans, Tuning.net.max_fighters), what + "has a panel per slot " + tag)
	await _assert_fits(j, what + "(nobody joined) " + tag)
	j.join(Bindings.Kind.PAD, 0)
	m.join(Bindings.Kind.PAD, 0, REMOTE_PEERS[0], LONG_PLAYER_NAME)
	var longest := _longest_character()
	for s in m.slots:
		s.char_index = longest
	m.coop_ally = true
	m.coop_ally_char = longest
	m.coop_ally_level = 0
	m.coop_structure = CoopConfig.Structure.WAVES
	j._refresh()
	var colors := [u.color_p1, u.color_p2, u.color_p3, u.color_p4]
	var colored := true
	for i in j._ui.size():
		colored = colored and j._ui[i]["color"] == colors[i]
	check(colored and u.color_p3 != u.color_p1 and u.color_p4 != u.color_p2,
			what + "P1..P4 have their own colours " + tag)
	var last := j.slots.size() - 1
	var ally_ui: Dictionary = j._ui[last]
	check(j.ally_slots() == [last] and (ally_ui["header"] as Label).text == "CPU ALLY"
			and (ally_ui["character"] as Label).text == MenuHelpers.character_name(MenuHelpers.character_ids()[longest]),
			what + "the ally's place shows the CPU ally " + tag)
	check(not (j._ui[2]["header"] as Label).text.contains("ALLY"), what + "the other empty slot stays open " + tag)
	check(j._status_label.text.begins_with("Ready up") and j._status_label.text.contains("can still join"),
			what + "status: ready up, more can join (got %s) %s" % [j._status_label.text, tag])
	(j._ui[0]["device"] as Label).text = LONG_PAD_NAME
	await _assert_fits(j, what + "(host + remote + empty + ally) " + tag)
	var cut := truncated(j, LONG_PAD_NAME)
	check(cut.is_empty(), what + "shows every row / name untrimmed " + tag)
	for c in cut.slice(0, 6):
		print("    trimmed: ", c)
	m.join(Bindings.Kind.PAD, 0, REMOTE_PEERS[1], LONG_PLAYER_NAME)
	m.slots[0].state = LobbyModel.SlotState.READY
	for s in m.slots:
		s.char_index = longest
	j._refresh()
	check(m.first_free_slot() < 0 and j._status_label.text == "Waiting for everyone to ready up...",
			what + "status once full and ready: waiting for the others (got %s) %s" % [j._status_label.text, tag])
	await _assert_fits(j, what + "(full with the ally) " + tag)
	m.coop_ally = false
	j._refresh()
	check(j.ally_slots().is_empty() and (j._ui[last]["header"] as Label).text != "CPU ALLY",
			what + "ally off: the last slot is a player slot again " + tag)
	m.join(Bindings.Kind.PAD, 0, REMOTE_PEERS[2], LONG_PLAYER_NAME)
	for s in m.slots:
		s.char_index = longest
	j._refresh()
	await _assert_fits(j, what + "(four players) " + tag)
	j.queue_free()
	Net.leave()
	await frames(1)


## Online co-op results: a column per human (one taken over by a CPU) and
## the online buttons, the vote one called Retry.
func _check_online_coop_results(tag: String) -> void:
	var saved := Game.last_result
	var net := LoopbackNetwork.new(1)
	Net.start_host(net.create_host())
	var coop := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	coop.coop = CoopConfig.new()
	coop.coop.structure = CoopConfig.Structure.WAVES
	var stats := {}
	var n := mini(Tuning.net.max_humans, Tuning.net.max_fighters)
	for i in n:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = MenuHelpers.character_ids()[_longest_character()]
		p.owner_peer = Net.local_peer() if i == 0 else REMOTE_PEERS[i - 1]
		p.display_name = LONG_PLAYER_NAME
		coop.players.append(p)
		stats[i] = {RunStats.KOS: 12, RunStats.DAMAGE: 4321.0, RunStats.BEST_COMBO: 23,
				RunStats.REVIVES: 3, RunStats.PERFECT_DODGES: 17}
	Net.room.last_config = coop
	Net.room._set_phase(OnlineRoom.Phase.MATCH)
	Net.room.match_finished()
	Game.last_result = {"winner_slot": 0, "wins": PackedInt32Array([1, 0]), "config": coop, "stats": stats,
			"run": {"cleared": true, "frames": 7380, "seconds": 123.0, "waves_cleared": 3},
			"cpu_takeovers": PackedInt32Array([n - 1])}
	var r := (load(Game.SCENE_RESULTS) as PackedScene).instantiate() as ResultsScreen
	r.navigate = func(_path: String) -> void: pass
	_vp.add_child(r)
	await frames(3)
	await _assert_fits(r, "results screen (online co-op, %d players) %s" % [n, tag])
	check(r._table.columns == 1 + n, "online co-op results: a column per player " + tag)
	var takeover := Tuning.hud.text_cpu_takeover % LONG_PLAYER_NAME
	var tags: Array = r._table.get_children().slice(1, 1 + n).map(func(l: Node) -> String: return (l as Label).text)
	check(tags[n - 1] == takeover and tags[0] == LONG_PLAYER_NAME,
			"online co-op results: a taken-over slot reads %s (got %s) %s" % [takeover, tags, tag])
	check(r._rematch_btn.text.begins_with("Retry ("), "online co-op results: the vote button is Retry " + tag)
	var cut := truncated(r, "")
	check(cut.is_empty(), "online co-op results: names untrimmed " + tag)
	for c in cut.slice(0, 6):
		print("    trimmed: ", c)
	r.queue_free()
	Net.leave()
	await frames(1)
	Game.last_result = saved


func _longest_character() -> int:
	var ids := MenuHelpers.character_ids()
	var best := 0
	for i in ids.size():
		if MenuHelpers.character_name(ids[i]).length() > MenuHelpers.character_name(ids[best]).length():
			best = i
	return best


func _find(n: Node, pred: Callable) -> Node:
	for c in n.get_children():
		if pred.call(c):
			return c
		var d := _find(c, pred)
		if d != null:
			return d
	return null
