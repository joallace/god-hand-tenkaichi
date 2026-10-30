class_name ResultsScreen
extends Control
## Post-match screen. Reads Game.last_result:
##   {"winner_slot": int (-1 = draw), "wins": PackedInt32Array (by team),
##    "config": MatchConfig}
## Versus: the headline names the winner (a team of 2+ by every tag, "P1 &
## P3 WIN!") in the winner slot's colour; the tally lists the teams (from
## the config) with their wins.
## Co-op runs (config.mode COOP) show STAGE CLEAR / WIPED OUT: the run is
## cleared when the winner slot is one of config.players (team 0; enemies
## aren't listed there), or when last_result has "cleared": true. Below it:
## the team line (run shape / waves cleared, run time; from "run") and a
## stats table with one column per team-0 player (rows RunStats.ROWS, from
## "stats", see presentation/run_stats.gd).
##
## Online (the config is_online(); SPEC_ONLINE.md §10.6, §13) the buttons are
## Rematch (this peer's vote in Net.room; the host starts it once every human
## of the last match voted, and Net turns that into the match), Lobby (host
## takes the room back; every peer follows on phase_changed -> LOBBY), Save
## replay (copies last_result "replay_path") and Leave (also ui_cancel).
## Peers of the match that left show as "<name> disconnected"; a forfeit
## (end_reason &"forfeit") names the losing team. An online co-op run has
## the same buttons with Rematch called Retry; its stats table names the
## human slots a CPU took over (last_result "cpu_takeovers") "CPU (<name>)".

const ELLIPSIS := "…"
const NAME_SEP := ", "
const TALLY_SEP := "   |   "

var _headline: Label
var _tally: Label
var _rematch_btn: Button
var _list: Container
var _table: GridContainer  # co-op only
var _table_scroll: ScrollContainer  # co-op only
var _col: VBoxContainer
var _t := 0.0
# Online only.
var _online := false
var _lobby_btn: Button
var _save_btn: Button
var _vote_label: Label
var _status_label: Label
var _save_label: Label
## Scene changes go through this when set (tests); else Game.goto.
var navigate: Callable
## The path of the last scene change this screen asked for (tests).
var went_to: String = ""


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var res: Dictionary = Game.last_result
	var winner: int = int(res.get("winner_slot", -1))
	var wins: PackedInt32Array = PackedInt32Array(res.get("wins", PackedInt32Array()))
	var cfg: MatchConfig = res.get("config") as MatchConfig

	var col := VBoxContainer.new()
	_col = col
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", u.results_coop_separation if is_coop(res) else u.results_separation)

	_headline = MenuHelpers.title(headline_text(res))
	if is_coop(res):
		_headline.add_theme_color_override("font_color", u.color_ready if coop_cleared(res) else u.color_text_dim)
	elif winner >= 0:
		_headline.add_theme_color_override("font_color", u.player_color(winner))
	col.add_child(_headline)

	if is_coop(res):
		_tally = MenuHelpers.label(coop_team_text(res), &"", HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_tally = MenuHelpers.label(tally_text(wins, cfg), &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_tally.add_theme_color_override("font_color", u.color_text)
	col.add_child(_tally)
	if is_coop(res) and cfg != null:
		col.add_child(_build_stats_panel(res, cfg))

	_online = cfg != null and cfg.is_online()
	if _online:
		_build_online(res)
	else:
		_rematch_btn = MenuHelpers.button("Retry" if is_coop(res) else "Rematch", _on_rematch, cfg == null)
		_list = MenuHelpers.vlist([
			_rematch_btn,
			MenuHelpers.button("Change Setup", _on_change_setup),
			MenuHelpers.button("Main Menu", _on_main_menu),
		])
		col.add_child(_list)
	add_child(MenuHelpers.centered(col))
	_fit_table()
	MenuHelpers.focus_first(_list)
	# The host already took the room back before this screen loaded.
	if _online and Net.room != null and Net.room.phase == OnlineRoom.Phase.LOBBY:
		_on_phase_changed.call_deferred(OnlineRoom.Phase.LOBBY)


static func headline_text(res: Dictionary) -> String:
	if res.is_empty():
		return "NO CONTEST"
	if is_coop(res):
		return "STAGE CLEAR!" if coop_cleared(res) else "WIPED OUT"
	var winner: int = int(res.get("winner_slot", -1))
	if winner < 0:
		return "DRAW!"
	var cfg := res.get("config") as MatchConfig
	if cfg != null:
		var team := team_slots(cfg, winner)
		if team.size() > 1:
			var tags: PackedStringArray = []
			for s in team:
				tags.append(cfg.player_tag(s).to_upper())
			return UiTheme.tuning().results_text_team_winner % Tuning.hud.text_team_join.join(tags)
	if cfg != null and cfg.player_tag(winner) == "CPU":
		return "CPU WINS!"
	if cfg != null and cfg.is_online():
		return "%s WINS!" % cfg.player_tag(winner).to_upper()
	return "PLAYER %d WINS!" % (winner + 1)


static func is_coop(res: Dictionary) -> bool:
	var cfg := res.get("config") as MatchConfig
	return cfg != null and cfg.mode == MatchConfig.Mode.COOP


static func coop_cleared(res: Dictionary) -> bool:
	if res.has("cleared"):
		return bool(res["cleared"])
	var run: Dictionary = res.get("run", {})
	if run.has("cleared"):
		return bool(run["cleared"])
	var winner: int = int(res.get("winner_slot", -1))
	var cfg := res.get("config") as MatchConfig
	if winner < 0 or cfg == null:
		return false
	for p in cfg.players:
		if p.slot == winner:
			return true
	return false


## Team line: run shape (or waves cleared in a Waves run) and the run time.
static func coop_team_text(res: Dictionary) -> String:
	var cfg := res.get("config") as MatchConfig
	var run: Dictionary = res.get("run", {})
	var parts: PackedStringArray = []
	if cfg != null and cfg.coop != null:
		if cfg.coop.structure == CoopConfig.Structure.WAVES:
			var waves := int(run.get("waves_cleared", -1))
			if waves < 0:
				parts.append("Endless waves" if cfg.coop.endless else "%d waves" % cfg.coop.waves.size())
			elif cfg.coop.endless:
				parts.append("Waves cleared: %d" % waves)
			else:
				parts.append("Waves cleared: %d / %d" % [waves, cfg.coop.waves.size()])
		else:
			parts.append("Brawl: %d enemies" % cfg.coop.enemy_count)
	if run.has("seconds"):
		parts.append("Time %s" % time_text(float(run["seconds"])))
	return "   |   ".join(parts)


## "m:ss" (whole seconds).
static func time_text(seconds: float) -> String:
	var s := maxi(floori(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]


## One stat cell; "-" when the run recorded nothing for it.
static func stat_text(stats: Dictionary, slot: int, key: String) -> String:
	var rec: Dictionary = stats.get(slot, {})
	if not rec.has(key):
		return "-"
	if key == RunStats.DAMAGE:
		return "%d" % roundi(float(rec[key]))
	return str(int(rec[key]))


func _build_stats_panel(res: Dictionary, cfg: MatchConfig) -> Control:
	var u := UiTheme.tuning()
	var stats: Dictionary = res.get("stats", {})
	_table = GridContainer.new()
	_table.columns = 1 + cfg.players.size()
	_table.add_theme_constant_override("h_separation", u.results_table_h_gap)
	_table.add_theme_constant_override("v_separation", u.results_table_v_gap)
	_add_cell("", &"", u.results_label_col_width)
	var taken := PackedInt32Array(res.get("cpu_takeovers", PackedInt32Array()))
	for p in cfg.players:
		var tag := _add_cell(player_column_tag(cfg, p.slot, taken), &"", u.results_player_col_width,
				HORIZONTAL_ALIGNMENT_CENTER)
		tag.add_theme_color_override("font_color", _tag_color(cfg, p.slot, taken))
		# Long online names / "CPU (<name>)" wrap inside the column.
		tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_add_cell("", &"HintLabel", u.results_label_col_width)
	for p in cfg.players:
		var fighter := _add_cell(MenuHelpers.character_name(p.character_id), &"HintLabel",
				u.results_player_col_width, HORIZONTAL_ALIGNMENT_CENTER)
		fighter.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for row: Array in RunStats.ROWS:
		var name_cell := _add_cell(String(row[1]), &"", u.results_label_col_width)
		name_cell.add_theme_color_override("font_color", u.color_text_dim)
		for p in cfg.players:
			_add_cell(stat_text(stats, p.slot, String(row[0])), &"", u.results_player_col_width,
					HORIZONTAL_ALIGNMENT_CENTER)

	_table_scroll = ScrollContainer.new()
	_table_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_table_scroll.add_child(_table)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, u.results_panel_padding)
	margin.add_child(_table_scroll)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_child(margin)
	return panel


## Size the scroll box to the table (themed, so once in the tree), capped at
## results_table_max_height; taller tables scroll.
func _fit_table() -> void:
	if _table == null:
		return
	var need := _table.get_combined_minimum_size()
	_table_scroll.custom_minimum_size = Vector2(need.x, minf(need.y, UiTheme.tuning().results_table_max_height))


func _add_cell(text: String, variation: StringName, min_width: int,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := MenuHelpers.label(text, variation, align)
	l.custom_minimum_size.x = min_width
	_table.add_child(l)
	return l


## A stats column's name: the player's tag, "CPU (<name>)" when a CPU took
## the slot over (`taken`).
static func player_column_tag(cfg: MatchConfig, slot: int, taken: PackedInt32Array) -> String:
	var tag := cfg.player_tag(slot)
	return Tuning.hud.text_cpu_takeover % tag if slot in taken else tag


static func _tag_color(cfg: MatchConfig, slot: int, taken: PackedInt32Array) -> Color:
	var u := UiTheme.tuning()
	if cfg.player_tag(slot) == "CPU" or slot in taken:
		return u.color_text_dim
	return u.player_color(slot)


## Versus score line; `wins` is indexed by team. Two teams: "<A>   2  -  1
## <B>" (the lowest slot's team first, teammates joined by text_team_join);
## 3+ teams (FFA): every team with its wins, TALLY_SEP between them.
static func tally_text(wins: PackedInt32Array, cfg: MatchConfig) -> String:
	if cfg == null:
		return "P1   %d  -  %d   P2" % [wins[0], wins[1]] if wins.size() >= 2 else ""
	var names: PackedStringArray = []
	var scores: Array[int] = []
	for team: Array[int] in teams(cfg):
		var tags: PackedStringArray = []
		for s in team:
			var p := cfg.players[_player_index(cfg, s)]
			tags.append("%s (%s)" % [cfg.player_tag(s), MenuHelpers.character_name(p.character_id)])
		names.append(Tuning.hud.text_team_join.join(tags))
		var id := _team_of(cfg.players[_player_index(cfg, team[0])])
		scores.append(wins[id] if id < wins.size() else 0)
	if names.size() < 2:
		return ""
	if names.size() == 2:
		return "%s   %d  -  %d   %s" % [names[0], scores[0], scores[1], names[1]]
	var parts: PackedStringArray = []
	for i in names.size():
		parts.append("%s  %d" % [names[i], scores[i]])
	return TALLY_SEP.join(parts)


## The config's teams (slot lists, ascending), ordered by their lowest slot.
static func teams(cfg: MatchConfig) -> Array[Array]:
	var by_team := {}  # team id -> Array[int] of slots
	var order: Array[int] = []
	var slots: Array[int] = []
	for p in cfg.players:
		slots.append(p.slot)
	slots.sort()
	for s in slots:
		var id := _team_of(cfg.players[_player_index(cfg, s)])
		if not by_team.has(id):
			var empty: Array[int] = []
			by_team[id] = empty
			order.append(id)
		(by_team[id] as Array[int]).append(s)
	var out: Array[Array] = []
	for id in order:
		out.append(by_team[id])
	return out


## Slots on the team of `slot` (ascending; just `slot` if it isn't listed).
static func team_slots(cfg: MatchConfig, slot: int) -> Array[int]:
	for team: Array[int] in teams(cfg):
		if slot in team:
			return team
	var out: Array[int] = [slot]
	return out


static func _player_index(cfg: MatchConfig, slot: int) -> int:
	for i in cfg.players.size():
		if cfg.players[i].slot == slot:
			return i
	return -1


func _process(delta: float) -> void:
	_t += delta
	if _headline.size.x > 0.0:
		_headline.pivot_offset = _headline.size * 0.5
		var u := UiTheme.tuning()
		_headline.scale = Vector2.ONE * (1.0 + u.results_pulse_amount * sin(_t * u.results_pulse_speed))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		if _online:
			_on_leave()
		else:
			_on_main_menu()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		MenuHelpers.focus_first(_list)


func _on_rematch() -> void:
	var cfg: MatchConfig = Game.last_result.get("config") as MatchConfig
	if cfg != null:
		Game.current_config = cfg
		Game.restart_match()


func _on_change_setup() -> void:
	var cfg: MatchConfig = Game.last_result.get("config") as MatchConfig
	if cfg != null:
		Lobby.pending_mode = cfg.mode
	_goto(Game.SCENE_LOBBY)


func _on_main_menu() -> void:
	_goto(Game.SCENE_MAIN_MENU)


func _goto(path: String) -> void:
	went_to = path
	if navigate.is_valid():
		navigate.call(path)
	else:
		Game.goto(path)


# --- online ---------------------------------------------------------------------

func _build_online(res: Dictionary) -> void:
	var u := UiTheme.tuning()
	var room := Net.room
	var info := MenuHelpers.label("\n".join(match_end_lines(res, room.departed if room != null else {})),
			&"", HORIZONTAL_ALIGNMENT_CENTER)
	info.add_theme_color_override("font_color", u.color_error)
	info.visible = not info.text.is_empty()
	_status_label = info
	_col.add_child(info)

	var host := room != null and room.is_host()
	_rematch_btn = MenuHelpers.button(_rematch_word(), _on_online_rematch, room == null)
	_lobby_btn = MenuHelpers.button("Lobby" if host or room == null else "Lobby (Host picks)",
			_on_online_lobby, not host)
	var replay_path := String(res.get("replay_path", ""))
	_save_btn = MenuHelpers.button("Save replay", _on_save_replay,
			replay_path.is_empty() or not FileAccess.file_exists(replay_path))
	var buttons: Array = [_rematch_btn, _lobby_btn, _save_btn, MenuHelpers.button("Leave", _on_leave)]
	if is_coop(res):
		# Under the stats table: two columns, so the screen keeps its height.
		var grid := GridContainer.new()
		grid.columns = u.results_online_coop_button_columns
		grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		grid.add_theme_constant_override("h_separation", u.list_separation)
		grid.add_theme_constant_override("v_separation", u.list_separation)
		for b: Button in buttons:
			grid.add_child(b)
		_list = grid
	else:
		_list = MenuHelpers.vlist(buttons)
	_col.add_child(_list)

	_vote_label = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_col.add_child(_vote_label)
	_save_label = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_col.add_child(_save_label)

	if room != null:
		room.changed.connect(_refresh_online)
		room.phase_changed.connect(_on_phase_changed)
		room.peer_departed.connect(_on_peer_departed)
	_refresh_online()


## "<name> disconnected" for every human peer of the match in `departed`
## (peer -> name), and for a forfeit "<names> forfeited" (the losing teams'
## humans that are still here; a disconnect forfeit is the line above).
static func match_end_lines(res: Dictionary, departed: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	var cfg := res.get("config") as MatchConfig
	if cfg == null:
		return out
	for peer in _human_peers(cfg):
		if departed.has(peer):
			out.append("%s disconnected" % _peer_name(cfg, peer, departed))
	if StringName(res.get("end_reason", &"")) != &"forfeit":
		return out
	var winner := int(res.get("winner_slot", -1))
	var win_team := -1
	for p in cfg.players:
		if p.slot == winner:
			win_team = _team_of(p)
	if win_team < 0:
		return out
	var names: PackedStringArray = []
	for p in cfg.players:
		if _team_of(p) != win_team and p.input_kind != PlayerSlotConfig.InputKind.CPU \
				and not departed.has(p.owner_peer):
			names.append(cfg.player_tag(p.slot))
	if not names.is_empty():
		out.append("%s forfeited" % NAME_SEP.join(names))
	return out


## A slot's team (-1 in the config = its own team, the slot).
static func _team_of(p: PlayerSlotConfig) -> int:
	return p.team if p.team >= 0 else p.slot


## Owner peers of the human slots, in slot order, once each.
static func _human_peers(cfg: MatchConfig) -> Array[int]:
	var out: Array[int] = []
	for p in cfg.players:
		if p.input_kind != PlayerSlotConfig.InputKind.CPU and p.owner_peer != 0 and not p.owner_peer in out:
			out.append(p.owner_peer)
	return out


## The match's name for `peer`, else the room's (departed), else a number.
static func _peer_name(cfg: MatchConfig, peer: int, departed: Dictionary) -> String:
	for p in cfg.players:
		if p.owner_peer == peer and p.display_name != "":
			return p.display_name
	if departed.has(peer):
		return String(departed[peer])
	return "Player %d" % peer


## The shared config of the match the votes are about.
func _vote_config() -> MatchConfig:
	if Net.room != null and Net.room.last_config != null:
		return Net.room.last_config
	return Game.last_result.get("config") as MatchConfig


func _refresh_online() -> void:
	var room := Net.room
	var cfg := _vote_config()
	if room == null or cfg == null:
		_rematch_btn.disabled = true
		return
	var peers := _human_peers(cfg)
	var gone := 0
	var waiting: PackedStringArray = []
	var votes := 0
	for peer in peers:
		if room.departed.has(peer):
			gone += 1
		elif peer in room.rematch_votes:
			votes += 1
		else:
			waiting.append(_peer_name(cfg, peer, room.departed))
	var voted := room.local_peer() in room.rematch_votes
	var word := _rematch_word()
	_rematch_btn.text = "%s (%d/%d)" % ["Cancel " + word if voted else word, votes, peers.size()]
	_rematch_btn.disabled = gone > 0 or room.phase != OnlineRoom.Phase.RESULTS
	if gone > 0:
		_vote_label.text = "%s unavailable" % word
	elif voted and not waiting.is_empty():
		_vote_label.text = "Waiting for %s%s" % [NAME_SEP.join(waiting), ELLIPSIS]
	elif votes > 0:
		_vote_label.text = "%s requested" % word
	else:
		_vote_label.text = ""


## "Retry" for a co-op run, "Rematch" for versus (button and vote lines).
func _rematch_word() -> String:
	return "Retry" if is_coop(Game.last_result) else "Rematch"


func _on_peer_departed(_peer: int, _peer_name_text: String) -> void:
	if Net.room != null:
		_status_label.text = "\n".join(match_end_lines(Game.last_result, Net.room.departed))
		_status_label.visible = not _status_label.text.is_empty()
	_refresh_online()


func _on_phase_changed(phase: OnlineRoom.Phase) -> void:
	if phase == OnlineRoom.Phase.LOBBY and went_to.is_empty():
		_goto(Game.SCENE_LOBBY)


func _on_online_rematch() -> void:
	var room := Net.room
	if room == null:
		return
	room.request({"op": OnlineRoom.OP_REMATCH, "on": not room.local_peer() in room.rematch_votes})
	if room.phase == OnlineRoom.Phase.RESULTS:
		_refresh_online()


func _on_online_lobby() -> void:
	if Net.room != null and Net.room.is_host():
		Net.room.request({"op": OnlineRoom.OP_TO_LOBBY})


func _on_save_replay() -> void:
	var u := UiTheme.tuning()
	var replay := Replay.load_file(String(Game.last_result.get("replay_path", "")))
	# Browser: user:// is IndexedDB the player can't open, so download it.
	if replay != null and WebPage.is_browser():
		var file_name := replay.default_saved_name().validate_filename() + Replay.EXT
		WebPage.download(replay.to_bytes(), file_name)
		_save_label.text = "Downloaded %s" % file_name
		_save_label.add_theme_color_override("font_color", u.color_ok)
		_save_btn.disabled = true
		return
	var path := replay.save_copy() if replay != null else ""
	if path.is_empty():
		_save_label.text = "Could not save the replay"
		_save_label.add_theme_color_override("font_color", u.color_error)
		return
	_save_label.text = "Saved: %s" % ProjectSettings.globalize_path(path)
	_save_label.add_theme_color_override("font_color", u.color_ok)
	_save_btn.disabled = true


func _on_leave() -> void:
	Net.leave()
	_goto(Game.SCENE_MAIN_MENU)
