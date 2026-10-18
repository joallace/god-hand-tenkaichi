class_name ResultsScreen
extends Control
## Post-match screen. Reads Game.last_result:
##   {"winner_slot": int (-1 = draw), "wins": PackedInt32Array, "config": MatchConfig}

var _headline: Label
var _tally: Label
var _rematch_btn: Button
var _list: VBoxContainer
var _t := 0.0


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var res: Dictionary = Game.last_result
	var winner: int = int(res.get("winner_slot", -1))
	var wins: PackedInt32Array = PackedInt32Array(res.get("wins", PackedInt32Array()))
	var cfg: MatchConfig = res.get("config") as MatchConfig

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 30)

	_headline = MenuHelpers.title(headline_text(res))
	if winner >= 0:
		_headline.add_theme_color_override("font_color", u.color_p1 if winner == 0 else u.color_p2)
	col.add_child(_headline)

	_tally = MenuHelpers.label(tally_text(wins, cfg), &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_tally.add_theme_color_override("font_color", u.color_text)
	col.add_child(_tally)

	_rematch_btn = MenuHelpers.button("Rematch", _on_rematch, cfg == null)
	_list = MenuHelpers.vlist([
		_rematch_btn,
		MenuHelpers.button("Change Setup", _on_change_setup),
		MenuHelpers.button("Main Menu", _on_main_menu),
	])
	col.add_child(_list)
	add_child(MenuHelpers.centered(col))
	MenuHelpers.focus_first(_list)


static func headline_text(res: Dictionary) -> String:
	if res.is_empty():
		return "NO CONTEST"
	var winner: int = int(res.get("winner_slot", -1))
	if winner < 0:
		return "DRAW!"
	var cfg := res.get("config") as MatchConfig
	if cfg != null and cfg.player_tag(winner) == "CPU":
		return "CPU WINS!"
	return "PLAYER %d WINS!" % (winner + 1)


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
		_headline.scale = Vector2.ONE * (1.0 + 0.04 * sin(_t * 4.0))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		_on_main_menu()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		MenuHelpers.focus_first(_list)


func _on_rematch() -> void:
	var cfg: MatchConfig = Game.last_result.get("config") as MatchConfig
	if cfg != null:
		Game.start_match(cfg)


func _on_change_setup() -> void:
	var cfg: MatchConfig = Game.last_result.get("config") as MatchConfig
	if cfg != null:
		JoinScreen.pending_mode = cfg.mode
	Game.goto(Game.SCENE_JOIN)


func _on_main_menu() -> void:
	Game.goto(Game.SCENE_MAIN_MENU)
