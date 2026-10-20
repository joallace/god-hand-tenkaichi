extends Node
## Headless test for 3-4 local views and n-fighter versus presentation:
## a MatchScene with a 4-local-player 2v2 (teams) config, then a 3-local FFA
## with a slot gap (slots 0, 1, 3), then a 4-local co-op run. Checks the
## ViewLayout (2x2 grid of non-overlapping views inside the screen, a filler
## in the 4th cell for 3 views, exactly one 3D audio listener, quarter views
## at the full-screen FOV), MatchHud versus panels (no overlap, teams on
## their side, compact stacked rows, team pips), team winner texts, CoopViewHud
## inside a quarter view, and the results headline / tally for teams.
##   godot --headless res://tests/split4_test.tscn

var _ok := true


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	await _test_2v2()
	await _test_ffa_gap()
	await _test_coop_quarters()
	_test_results_texts()
	await _test_results_screen()
	Game.current_config = null
	Game.last_result = {}
	print("SPLIT4 TEST %s" % ("PASS" if _ok else "FAIL"))
	get_tree().quit(0 if _ok else 1)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)
	else:
		print("PASS ", what)


## A real device in a headless run must not drive these screens.
func _input(_event: InputEvent) -> void:
	get_viewport().set_input_as_handled()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


static func _config(mode: MatchConfig.Mode, slots: Array[int], teams: Array[int]) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(mode)
	for i in slots.size():
		var p := PlayerSlotConfig.new()
		p.slot = slots[i]
		p.team = teams[i]
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL
		p.device_kind = Bindings.Kind.KEYBOARD
		cfg.players.append(p)
	return cfg


func _start(cfg: MatchConfig) -> MatchScene:
	Game.current_config = cfg
	# Idle scripted sources instead of devices (this is about presentation;
	# Bindings only has keyboard layouts / binding maps for two players).
	get_tree().node_added.connect(_on_node_added)
	var m := (load(Game.SCENE_MATCH) as PackedScene).instantiate() as MatchScene
	add_child(m)
	get_tree().node_added.disconnect(_on_node_added)
	await _frames(4)
	return m


func _on_node_added(n: Node) -> void:
	if n is MatchDirector:
		(n as MatchDirector).source_factory = func(_p: PlayerSlotConfig) -> InputSource:
			return ScriptedInput.new()


func _stop(m: MatchScene) -> void:
	m.queue_free()
	get_tree().paused = false
	await _frames(2)


# --- views ------------------------------------------------------------------------

func _check_views(m: MatchScene, slots: Array[int], label: String) -> void:
	var screen := Rect2(Vector2.ZERO, m.views.size)
	_check(m.views.panels.size() == slots.size() and m.views.cameras.size() == slots.size(),
			"%s: %d views" % [label, slots.size()])
	var grid := m.views.get_node_or_null("Views") as GridContainer
	_check(grid != null and grid.columns == ViewLayout.GRID_COLUMNS, "%s: views in a 2x2 grid" % label)
	var rects: Array[Rect2] = []
	for i in slots.size():
		var panel := m.views.panels.get(slots[i]) as Control
		_check(panel != null, "%s: view for slot %d" % [label, slots[i]])
		if panel == null:
			continue
		var r := Rect2(panel.position + grid.position, panel.size)
		_check(r.size.x > screen.size.x * 0.4 and r.size.y > screen.size.y * 0.4,
				"%s: view %d is a quarter of the screen (%s)" % [label, slots[i], r])
		_check(screen.grow(0.5).encloses(r), "%s: view %d inside the screen" % [label, slots[i]])
		for o in rects:
			_check(not o.intersects(r), "%s: views %s and %s don't overlap" % [label, o, r])
		rects.append(r)
		# Row-major in slot order.
		var col := i % ViewLayout.GRID_COLUMNS
		_check((col == 0) == (r.position.x < screen.size.x * 0.5)
				and (i < ViewLayout.GRID_COLUMNS) == (r.position.y < screen.size.y * 0.5),
				"%s: view %d in grid cell %d" % [label, slots[i], i])
		# The SubViewport renders the cell (canvas -> pixel fit).
		var c := panel.get_node("Container") as SubViewportContainer
		var k := m.views.pixel_scale()
		_check(c.size.is_equal_approx(panel.size * k), "%s: view %d container fitted" % [label, slots[i]])
		var cam := m.views.cameras[slots[i]] as FighterCamera
		_check(not cam.split, "%s: quarter view camera keeps the full-screen FOV" % label)
	var fillers := grid.find_children("Filler", "ColorRect", false, false)
	_check(fillers.size() == ViewLayout.GRID_COLUMNS * ViewLayout.GRID_COLUMNS - slots.size(),
			"%s: %d filler cell(s)" % [label, fillers.size()])
	var listeners := 0
	for vp in m.views.find_children("*", "SubViewport", true, false):
		if (vp as SubViewport).audio_listener_enable_3d:
			listeners += 1
	_check(listeners == 1, "%s: exactly one 3D audio listener (%d)" % [label, listeners])
	var first := (m.views.panels[slots[0]] as Control).get_node("Container/SubViewport") as SubViewport
	_check(first.audio_listener_enable_3d, "%s: the listener is the first view's" % label)


# --- HUD --------------------------------------------------------------------------

## Every widget rect of every panel, tagged by slot.
func _panel_rects(hud: MatchHud) -> Array:
	var out: Array = []
	for slot: int in hud.panels:
		var p: Dictionary = hud.panels[slot]
		for key in ["name", "health", "ki"]:
			var c := p[key] as Control
			out.append([slot, key, Rect2(c.position, c.size)])
	return out


func _check_hud(m: MatchScene, left: Array[int], right: Array[int], label: String) -> void:
	var hud := m.hud
	_check(hud.panels.size() == left.size() + right.size(), "%s: a panel per fighter" % label)
	var half := hud.root.size.x * 0.5
	for side in 2:
		var slots: Array[int] = left if side == 0 else right
		for row in slots.size():
			var p: Dictionary = hud.panels.get(slots[row], {})
			if p.is_empty():
				_check(false, "%s: panel for slot %d" % [label, slots[row]])
				continue
			var hb := p["health"] as Control
			var on_right := hb.position.x >= half
			_check(on_right == (side == 1) and bool(p["right"]) == (side == 1),
					"%s: slot %d on the %s" % [label, slots[row], "right" if side == 1 else "left"])
			_check(int(p["row"]) == row, "%s: slot %d in row %d" % [label, slots[row], row])
			_check(bool(p["compact"]), "%s: stacked panels are compact" % label)
	var rects := _panel_rects(hud)
	var overlaps := 0
	for i in rects.size():
		var r: Rect2 = rects[i][2]
		_check(Rect2(Vector2.ZERO, hud.root.size).encloses(r), "%s: %s of slot %d on screen" % [label, rects[i][1], rects[i][0]])
		for j in range(i + 1, rects.size()):
			if rects[i][0] != rects[j][0] and r.intersects(rects[j][2]):
				overlaps += 1
				printerr("  overlap: slot %d %s %s / slot %d %s %s" % [rects[i][0], rects[i][1], r,
						rects[j][0], rects[j][1], rects[j][2]])
	_check(overlaps == 0, "%s: panels don't overlap" % label)
	# Timer stays clear of every panel.
	var timer := Rect2(hud.timer_label.position, hud.timer_label.size)
	for e: Array in rects:
		_check(not timer.intersects(e[2]), "%s: timer clear of slot %d %s" % [label, e[0], e[1]])


func _pips_won(hud: MatchHud, slot: int) -> int:
	var n := 0
	for pip in (hud.panels[slot]["pips"] as HBoxContainer).get_children():
		var sb := (pip as Panel).get_theme_stylebox("panel") as StyleBoxFlat
		if sb.bg_color.is_equal_approx(Tuning.hud.pip_won_color):
			n += 1
	return n


func _test_2v2() -> void:
	# Teams: slots 0 + 2 vs 1 + 3.
	var cfg := _config(MatchConfig.Mode.LOCAL_VERSUS, [0, 1, 2, 3], [0, 1, 0, 1])
	var m := await _start(cfg)
	_check(m.director.fighters.size() == 4, "2v2: four fighters")
	_check_views(m, [0, 1, 2, 3], "2v2")
	_check_hud(m, [0, 2], [1, 3], "2v2")
	var hud := m.hud
	# Pips follow the team's wins.
	m.director.wins[1] = 1
	hud._refresh_pips()
	_check(_pips_won(hud, 1) == 1 and _pips_won(hud, 3) == 1 and _pips_won(hud, 0) == 0,
			"2v2: both team-1 panels show the team's round")
	# Team winner texts.
	_check(hud.winner_text(0, false) == Tuning.hud.text_team_round_winner % "P1 & P3", "2v2: team round winner text")
	hud._on_confirmed_event(0, &"match_ended", {"winner_slot": 1})
	_check(hud.announcer.text == Tuning.hud.text_team_match_winner % "P2 & P4",
			"2v2: match winner names the team (%s)" % hud.announcer.text)
	await _stop(m)


func _test_ffa_gap() -> void:
	# FFA of three with a slot gap: teams = slots.
	var cfg := _config(MatchConfig.Mode.LOCAL_VERSUS, [0, 1, 3], [-1, -1, -1])
	var m := await _start(cfg)
	_check(m.director.fighters.size() == 3, "ffa: three fighters")
	_check_views(m, [0, 1, 3], "ffa")
	_check_hud(m, [0, 3], [1], "ffa")
	var hud := m.hud
	_check(hud.winner_text(3, true) == Tuning.hud.text_match_winner % 4, "ffa: single winner text unchanged")
	m.director.wins[3] = 1
	hud._refresh_pips()
	_check(_pips_won(hud, 3) == 1 and _pips_won(hud, 0) == 0 and _pips_won(hud, 1) == 0,
			"ffa: pips per fighter (slot gap)")
	await _stop(m)


func _test_coop_quarters() -> void:
	var cfg := _config(MatchConfig.Mode.COOP, [0, 1, 2, 3], [0, 0, 0, 0])
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = 2
	cfg.round_time_seconds = 0
	var m := await _start(cfg)
	_check_views(m, [0, 1, 2, 3], "coop")
	_check(m.coop_huds.size() == 4, "coop: a CoopViewHud per quarter view")
	for slot: int in m.coop_huds:
		var ch := m.coop_huds[slot] as CoopViewHud
		var panel := m.views.panels[slot] as Control
		var view := Rect2(Vector2.ZERO, panel.size)
		_check(ch.size.is_equal_approx(panel.size), "coop: view %d HUD fills its quarter" % slot)
		_check(ch.partner_count() == 3, "coop: view %d lists 3 teammates" % slot)
		var bar := Rect2(ch._target_bar.position, ch._target_bar.size)
		_check(view.encloses(bar), "coop: view %d target bar inside the quarter" % slot)
		for p: Dictionary in ch._partners:
			var hb := p["health"] as Control
			var r := Rect2(hb.position, hb.size)
			_check(view.encloses(r) and not r.intersects(bar), "coop: view %d partner bar inside, clear of the target bar" % slot)
	_check(m.hud.panels.size() == 2, "coop: global HUD keeps two panels")
	await _stop(m)


# --- results ------------------------------------------------------------------------

func _test_results_texts() -> void:
	var cfg := _config(MatchConfig.Mode.LOCAL_VERSUS, [0, 1, 2, 3], [0, 1, 0, 1])
	var res := {"winner_slot": 0, "wins": PackedInt32Array([2, 1]), "config": cfg}
	_check(ResultsScreen.headline_text(res) == UiTheme.tuning().results_text_team_winner % "P1 & P3",
			"results: 2v2 headline names the team (%s)" % ResultsScreen.headline_text(res))
	var tally := ResultsScreen.tally_text(res["wins"], cfg)
	_check(tally.begins_with("P1 (") and tally.contains(" & P3 (") and tally.contains("2  -  1")
			and tally.contains("P2 (") and tally.contains(" & P4 ("), "results: 2v2 tally by team (%s)" % tally)
	# Online names.
	var online := _config(MatchConfig.Mode.ONLINE, [0, 1, 3], [0, 1, 0])
	var names := ["Ana", "Cy", "Bo"]
	for i in online.players.size():
		online.players[i].owner_peer = i + 1
		online.players[i].display_name = names[i]
	var ores := {"winner_slot": 0, "wins": PackedInt32Array([1, 0]), "config": online}
	_check(ResultsScreen.headline_text(ores) == UiTheme.tuning().results_text_team_winner % "ANA & BO",
			"results: online team headline (%s)" % ResultsScreen.headline_text(ores))
	ores["winner_slot"] = 1
	_check(ResultsScreen.headline_text(ores) == "CY WINS!", "results: online solo winner unchanged")
	# FFA of three: every fighter with its wins (wins by team = slot, gap at 2).
	var ffa := _config(MatchConfig.Mode.LOCAL_VERSUS, [0, 1, 3], [-1, -1, -1])
	var ffa_tally := ResultsScreen.tally_text(PackedInt32Array([1, 0, 0, 2]), ffa)
	_check(ffa_tally.contains("P1 (") and ffa_tally.contains("  1") and ffa_tally.contains("P4 (")
			and ffa_tally.ends_with("  2") and ffa_tally.contains(ResultsScreen.TALLY_SEP),
			"results: FFA tally lists every fighter (%s)" % ffa_tally)
	_check(ResultsScreen.headline_text({"winner_slot": 3, "wins": PackedInt32Array([1, 0, 0, 2]), "config": ffa})
			== "PLAYER 4 WINS!", "results: FFA headline")


func _test_results_screen() -> void:
	var cfg := _config(MatchConfig.Mode.LOCAL_VERSUS, [0, 1, 2, 3], [0, 1, 0, 1])
	Game.last_result = {"winner_slot": 1, "wins": PackedInt32Array([1, 2]), "config": cfg}
	var r := (load(Game.SCENE_RESULTS) as PackedScene).instantiate() as ResultsScreen
	r.navigate = func(_path: String) -> void: pass
	add_child(r)
	await _frames(3)
	_check(r._headline.text == UiTheme.tuning().results_text_team_winner % "P2 & P4", "results screen: team headline")
	_check(r._headline.get_theme_color("font_color").is_equal_approx(UiTheme.tuning().player_color(1)),
			"results screen: headline in the winner slot's colour")
	_check(r._tally.text.contains("1  -  2"), "results screen: team tally (%s)" % r._tally.text)
	r.queue_free()
	await _frames(2)
