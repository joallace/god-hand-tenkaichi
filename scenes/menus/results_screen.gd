class_name ResultsScreen
extends Control
## Post-match screen. Reads Game.last_result:
##   {"winner_slot": int (-1 = draw), "wins": PackedInt32Array, "config": MatchConfig}
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
## (end_reason &"forfeit") names the losing team.

const ELLIPSIS := "…"
const NAME_SEP := ", "

var _headline: Label
var _tally: Label
var _rematch_btn: Button
var _list: VBoxContainer
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
		_headline.add_theme_color_override("font_color", u.color_p1 if winner == 0 else u.color_p2)
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
	for p in cfg.players:
		var tag := _add_cell(cfg.player_tag(p.slot), &"", u.results_player_col_width, HORIZONTAL_ALIGNMENT_CENTER)
		tag.add_theme_color_override("font_color", _tag_color(cfg, p.slot))
	_add_cell("", &"HintLabel", u.results_label_col_width)
	for p in cfg.players:
		_add_cell(MenuHelpers.character_name(p.character_id), &"HintLabel", u.results_player_col_width,
				HORIZONTAL_ALIGNMENT_CENTER)
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


static func _tag_color(cfg: MatchConfig, slot: int) -> Color:
	var u := UiTheme.tuning()
	if cfg.player_tag(slot) == "CPU":
		return u.color_text_dim
	return u.color_p1 if slot == 0 else u.color_p2


static func tally_text(wins: PackedInt32Array, cfg: MatchConfig) -> String:
	if wins.size() < 2:
		return ""
	var names: PackedStringArray = []
	for i in wins.size():
		var n := cfg.player_tag(i) if cfg != null else "P%d" % (i + 1)
		if cfg != null and i < cfg.players.size():
			n += " (%s)" % MenuHelpers.character_name(cfg.players[i].character_id)
		names.append(n)
	return "%s   %d  -  %d   %s" % [names[0], wins[0], wins[1], names[1]]


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
	_rematch_btn = MenuHelpers.button("Rematch", _on_online_rematch, room == null)
	_lobby_btn = MenuHelpers.button("Lobby" if host or room == null else "Lobby (Host picks)",
			_on_online_lobby, not host)
	var replay_path := String(res.get("replay_path", ""))
	_save_btn = MenuHelpers.button("Save replay", _on_save_replay,
			replay_path.is_empty() or not FileAccess.file_exists(replay_path))
	_list = MenuHelpers.vlist([
		_rematch_btn,
		_lobby_btn,
		_save_btn,
		MenuHelpers.button("Leave", _on_leave),
	])
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
	_rematch_btn.text = "%s (%d/%d)" % ["Cancel Rematch" if voted else "Rematch", votes, peers.size()]
	_rematch_btn.disabled = gone > 0 or room.phase != OnlineRoom.Phase.RESULTS
	if gone > 0:
		_vote_label.text = "Rematch unavailable"
	elif voted and not waiting.is_empty():
		_vote_label.text = "Waiting for %s%s" % [NAME_SEP.join(waiting), ELLIPSIS]
	elif votes > 0:
		_vote_label.text = "Rematch requested"
	else:
		_vote_label.text = ""


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
