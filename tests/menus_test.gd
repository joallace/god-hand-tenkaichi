extends Node
## Headless menu test. Run as a scene (needs autoloads):
##   godot --headless res://tests/menus_test.tscn
## Leaves user://controls.cfg exactly as it found it.

var _fails := 0
var _cfg_existed := false
var _cfg_bytes := PackedByteArray()


func _ready() -> void:
	_backup_cfg()
	await _test_pad_ui_actions()
	await _test_main_menu()
	await _test_join_screen()
	await _test_join_screen_cpu()
	await _test_join_screen_coop()
	await _test_controls_screen()
	await _test_controls_overlay()
	await _test_results_screen()
	await _test_results_screen_coop()
	_test_restart_match()
	_restore_cfg()
	print("MENUS %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func seconds(t: float) -> void:
	await get_tree().create_timer(t, true).timeout


func spawn(path: String) -> Node:
	var n := (load(path) as PackedScene).instantiate()
	add_child(n)
	return n


func pad(device: int, button: int, pressed := true) -> void:
	var e := InputEventJoypadButton.new()
	e.device = device
	e.button_index = button
	e.pressed = pressed
	e.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(e)
	await frames(2)


func pad_tap(device: int, button: int) -> void:
	await pad(device, button, true)
	await pad(device, button, false)


func key(code: int, pressed := true) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
	await frames(2)


func key_tap(code: int) -> void:
	await key(code, true)
	await key(code, false)


# --- Tests -----------------------------------------------------------------------

func _test_pad_ui_actions() -> void:
	var b := MenuHelpers.button("Probe")
	var pressed := [false]
	b.pressed.connect(func() -> void: pressed[0] = true)
	add_child(b)
	b.grab_focus()
	await frames(2)
	await pad_tap(1, JOY_BUTTON_A)
	check(pressed[0], "gamepad A presses the focused button (ui_accept)")
	var cancel := InputEventJoypadButton.new()
	cancel.device = 1
	cancel.button_index = JOY_BUTTON_B
	cancel.pressed = true
	check(cancel.is_action_pressed("ui_cancel"), "gamepad B maps to ui_cancel")
	b.queue_free()
	await frames(2)


func _test_main_menu() -> void:
	# Main-menu coverage moved to tests/online_menus_test.gd.
	pass


func _test_join_screen() -> void:
	Lobby.pending_mode = MatchConfig.Mode.LOCAL_VERSUS
	var j := spawn(Game.SCENE_LOBBY) as Lobby
	j.auto_start = false
	var requested: Array = []
	j.match_requested.connect(func(c: MatchConfig) -> void: requested.append(c))
	await frames(3)

	await pad_tap(0, JOY_BUTTON_START)
	check(j.slots[0].state == Lobby.SlotState.JOINED and j.slots[0].device_id == 0, "pad 0 joins slot P1")
	await pad_tap(0, JOY_BUTTON_START)  # same device: would READY, must not claim slot 2
	check(j.slots[1].state == Lobby.SlotState.EMPTY, "pad 0 cannot claim a second slot")
	check(j.slots[0].state == Lobby.SlotState.READY, "pad 0 START again readies")
	await pad_tap(0, JOY_BUTTON_B)
	check(j.slots[0].state == Lobby.SlotState.JOINED, "pad 0 B un-readies")

	await pad_tap(1, JOY_BUTTON_START)
	check(j.slots[1].state == Lobby.SlotState.JOINED and j.slots[1].device_id == 1
			and j.slots[1].device_kind == Bindings.Kind.PAD, "pad 1 joins slot P2")
	check(j.slots[0].device_id != j.slots[1].device_id, "slots have distinct devices")

	# Pad 1 leaves, keyboard takes slot 2 with layout B.
	await pad_tap(1, JOY_BUTTON_B)
	check(j.slots[1].state == Lobby.SlotState.EMPTY, "pad 1 B leaves")
	await key_tap(KEY_ENTER)
	check(j.slots[1].state == Lobby.SlotState.JOINED and j.slots[1].device_kind == Bindings.Kind.KEYBOARD,
			"Enter joins keyboard into P2")

	# Settings: P1 pad moves past Game to Rounds, then Timer, cycles to infinite.
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	check(j.slots[0].cursor == Lobby.Row.MODE, "down from fighter reaches the Game row")
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
	check(j.model.rounds_to_win == mini(Tuning.match_rules.rounds_to_win + 1, 5), "rounds to win changed by P1")
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	var opts := Tuning.match_rules.round_time_options
	var inf_idx := opts.find(0)
	var guard := 0
	while j.model.time_index != inf_idx and guard < 10:
		await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
		guard += 1
	check(j.model.time_index == inf_idx, "timer can be set to infinite")

	# Ready both: pad A and keyboard P2 LIGHT key (layout B: KP_1).
	await pad_tap(0, JOY_BUTTON_A)
	var p2_light: Dictionary = Bindings.get_binding(1, Bindings.Kind.KEYBOARD, "LIGHT")
	await key_tap(p2_light["i"])
	check(j.all_ready(), "both players ready")
	await seconds(UiTheme.tuning().join_start_delay + 0.3)
	check(requested.size() == 1, "match requested once after countdown")
	if requested.size() == 1:
		var cfg: MatchConfig = requested[0]
		check(cfg.mode == MatchConfig.Mode.LOCAL_VERSUS and cfg.players.size() == 2, "config mode/players")
		check(cfg.players[0].device_kind == Bindings.Kind.PAD and cfg.players[0].device_id == 0, "P1 config = pad 0")
		check(cfg.players[1].device_kind == Bindings.Kind.KEYBOARD and cfg.players[1].slot == 1, "P2 config = keyboard slot 1")
		check(cfg.round_time_seconds == 0 and cfg.is_infinite_time(), "config infinite timer")
	j.queue_free()
	await frames(2)


func _test_join_screen_cpu() -> void:
	Lobby.pending_mode = MatchConfig.Mode.VERSUS_CPU
	var j := spawn(Game.SCENE_LOBBY) as Lobby
	j.auto_start = false
	var requested: Array = []
	j.match_requested.connect(func(c: MatchConfig) -> void: requested.append(c))
	await frames(3)
	var cpu := j.cpu_slot()
	check(cpu == 1 and j.slots[cpu].state == Lobby.SlotState.READY, "CPU slot is pre-joined and ready")
	check(j.rows().has(Lobby.Row.CPU_LEVEL), "CPU mode offers a CPU level row")
	var start_level := j.slots[cpu].cpu_level
	check(start_level == Tuning.cpu.clamp_level(-1) or LobbyModel._memory.has("cpu_level"), "CPU level starts at the default")

	await pad_tap(0, JOY_BUTTON_START)
	check(j.slots[0].state == Lobby.SlotState.JOINED, "pad 0 joins the human slot")
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	check(j.slots[0].cursor == Lobby.Row.CPU_CHARACTER, "down past Game reaches CPU fighter row")
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	check(j.slots[0].cursor == Lobby.Row.CPU_LEVEL, "next row is CPU level")
	await pad_tap(0, JOY_BUTTON_DPAD_LEFT)
	check(j.slots[cpu].cpu_level == maxi(start_level - 1, 0), "left lowers the CPU level")
	for i in Tuning.cpu.level_count() + 2:
		await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
	check(j.slots[cpu].cpu_level == Tuning.cpu.level_count() - 1, "CPU level clamps at the top")
	check(j._cpu_level_label.text.contains(Tuning.cpu.level_name(Tuning.cpu.level_count() - 1)), "CPU level label shows the level name")

	await pad_tap(0, JOY_BUTTON_A)
	check(j.all_ready(), "human ready + CPU ready")
	await seconds(UiTheme.tuning().join_start_delay + 0.3)
	check(requested.size() == 1, "CPU match requested after countdown")
	if requested.size() == 1:
		var cfg: MatchConfig = requested[0]
		check(cfg.mode == MatchConfig.Mode.VERSUS_CPU, "config mode VERSUS_CPU")
		check(cfg.players[1].input_kind == PlayerSlotConfig.InputKind.CPU
				and cfg.players[1].cpu_level == Tuning.cpu.level_count() - 1, "config carries CPU and its level")
		check(cfg.player_tag(1) == "CPU" and cfg.player_tag(0) == "P1", "player tags name the CPU")
		var src := cfg.players[1].create_input_source() as CpuInput
		check(src != null and src.brain.level == Tuning.cpu.level_count() - 1, "CPU input source built at that level")
	LobbyModel._memory = {}
	Lobby.pending_mode = MatchConfig.Mode.LOCAL_VERSUS
	j.queue_free()
	await frames(2)


func _test_join_screen_coop() -> void:
	LobbyModel._coop_memory = {}
	Lobby.pending_mode = MatchConfig.Mode.COOP
	var j := spawn(Game.SCENE_LOBBY) as Lobby
	j.auto_start = false
	var requested: Array = []
	j.match_requested.connect(func(c: MatchConfig) -> void: requested.append(c))
	await frames(3)
	check(j.is_coop() and j.cpu_slot() < 0, "co-op join screen has two human slots")
	check(not j.rows().has(Lobby.Row.ROUNDS) and j.rows().has(Lobby.Row.ENEMY_COUNT), "co-op rows replace rounds")
	check(not j.rows().has(Lobby.Row.WAVES), "Waves row hidden in Brawl")
	check(not j.rows().has(Lobby.Row.ALLY_LEVEL), "ally rows hidden without an ally")
	check(not j.all_ready(), "nobody joined: not ready")

	await pad_tap(0, JOY_BUTTON_START)
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	check(j.slots[0].cursor == Lobby.Row.COOP_STRUCTURE, "down past Game reaches Run")
	await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
	check(j.model.coop_structure == CoopConfig.Structure.WAVES and j.rows().has(Lobby.Row.WAVES), "Mode -> Waves shows the Waves row")
	check((j._coop_labels[Lobby.Row.WAVES] as Label).visible, "Waves label visible in Waves mode")
	check((j._coop_labels[Lobby.Row.ENEMY_COUNT] as Label).text.contains("per wave"), "enemy count reads per wave")
	j.slots[0].cursor = Lobby.Row.WAVES
	j.model.coop_structure = CoopConfig.Structure.BRAWL
	j.model.fix_cursors()
	check(j.slots[0].cursor == Lobby.Row.COOP_STRUCTURE, "cursor on a hidden row falls back to Mode")
	j.slots[0].cursor = Lobby.Row.ALLY
	j.model._change_row(0, 1)
	check(j.model.coop_ally and j.rows().has(Lobby.Row.ALLY_LEVEL) and j.rows().has(Lobby.Row.ALLY_CHARACTER),
			"Ally -> CPU shows ally level and fighter rows")
	j.model.coop_ally = false
	j._refresh()

	# Solo run: P2 stays empty.
	await pad_tap(0, JOY_BUTTON_A)
	check(j.all_ready(), "solo human ready is enough")
	await seconds(UiTheme.tuning().join_start_delay + 0.3)
	check(requested.size() == 1, "co-op run requested after countdown")
	if requested.size() == 1:
		var cfg: MatchConfig = requested[0]
		check(cfg.mode == MatchConfig.Mode.COOP and cfg.players.size() == 1, "solo config: mode COOP, one player")
		check(cfg.players[0].team == 0 and cfg.players[0].slot == 0
				and cfg.players[0].input_kind == PlayerSlotConfig.InputKind.LOCAL and cfg.players[0].device_id == 0,
				"solo player is pad 0 on team 0")
		check(cfg.coop != null and cfg.coop.structure == CoopConfig.Structure.BRAWL
				and cfg.coop.enemy_count == Tuning.coop.default_enemy_count and not cfg.coop.ally_enabled,
				"coop fields from defaults")
		check(cfg.is_infinite_time() == (Tuning.match_rules.round_time_options.find(0) >= 0), "co-op defaults to no time limit")
		check(not cfg.friendly_fire, "friendly fire off by default")

	# Solo + ally, waves, friendly fire (built directly).
	j.model.coop_ally = true
	j.model.coop_ally_level = 2
	j.model.coop_ally_char = 0
	j.model.coop_structure = CoopConfig.Structure.WAVES
	j.model.coop_waves = 3
	j.model.friendly_fire = true
	var cfg2 := j.build_config()
	check(cfg2.players.size() == 2 and cfg2.players[1].input_kind == PlayerSlotConfig.InputKind.CPU
			and cfg2.players[1].team == 0 and cfg2.players[1].cpu_level == 2 and cfg2.players[1].slot == 1,
			"ally is a CPU slot on team 0 at its level")
	check(cfg2.player_tag(1) == "CPU", "ally tagged CPU")
	check(cfg2.coop.ally_enabled and cfg2.coop.ally_level == 2, "coop records the ally")
	check(cfg2.coop.structure == CoopConfig.Structure.WAVES and cfg2.coop.waves.size() == 3 and not cfg2.coop.endless,
			"3 waves")
	check(cfg2.friendly_fire, "friendly fire on")
	j.model.coop_waves = Tuning.coop.max_wave_count + 1
	var cfg3 := j.build_config()
	check(cfg3.coop.endless and cfg3.coop.waves.is_empty(), "past the max wave count = endless")
	j.model.coop_roster = 1
	check(j.build_config().coop.enemy_character == MenuHelpers.character_ids()[0], "roster pick sets the enemy character")
	j.model.coop_roster = 0
	check(j.build_config().coop.enemy_character == &"", "roster Random = empty id")

	# Two humans: keyboard joins P2.
	j.model.coop_ally = false
	j._started = false
	j.slots[0].state = Lobby.SlotState.JOINED
	await key_tap(KEY_ENTER)
	check(j.slots[1].state == Lobby.SlotState.JOINED, "keyboard joins P2 in co-op")
	var cfg4 := j.build_config()
	check(cfg4.players.size() == 2 and cfg4.players[1].device_kind == Bindings.Kind.KEYBOARD
			and cfg4.players[0].team == 0 and cfg4.players[1].team == 0, "two humans on team 0")
	check(not j.all_ready(), "a joined but unready P2 blocks the start")

	# Memory: a new visit restores the last run setup.
	j.model.coop_enemy_count = 7
	j.model.remember()
	j.queue_free()
	await frames(2)
	var j2 := spawn(Game.SCENE_LOBBY) as Lobby
	j2.auto_start = false
	await frames(3)
	check(j2.model.coop_enemy_count == 7, "co-op setup remembered across visits")
	j2.queue_free()
	LobbyModel._coop_memory = {}
	Lobby.pending_mode = MatchConfig.Mode.LOCAL_VERSUS
	await frames(2)


func _test_controls_screen() -> void:
	for s in Bindings.SLOT_COUNT:
		Bindings.reset_defaults(s)
	var c := spawn(Game.SCENE_CONTROLS) as ControlsScreen
	await frames(3)
	check(get_viewport().gui_get_focus_owner() == c._player_sel, "controls focuses Player selector")
	c._device_sel.cycle(1)  # -> Keyboard
	await frames(2)
	check(c.kind == Bindings.Kind.KEYBOARD and c._row_buttons.has("MOVE_FORWARD"), "keyboard rows listed")

	# Real flow: focus the LIGHT row, press+release Enter, then press Z.
	var row: Button = c._row_buttons["LIGHT"]
	row.grab_focus()
	await frames(2)
	await key(KEY_ENTER, true)
	await key(KEY_ENTER, false)
	check(c.is_listening(), "Enter on a row starts listening")
	check(Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "LIGHT")["i"] == KEY_J, "Enter press did not bind itself")
	await seconds(UiTheme.tuning().rebind_arm_delay + 0.1)
	await key_tap(KEY_Z)
	check(not c.is_listening(), "listening ends after key")
	check(Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "LIGHT") == {"t": "key", "i": KEY_Z}, "LIGHT rebound to Z")

	# Swap: bind HEAVY (I) to Z -> LIGHT gets I.
	c.begin_listen("HEAVY")
	await seconds(UiTheme.tuning().rebind_arm_delay + 0.1)
	await key_tap(KEY_Z)
	check(Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "HEAVY")["i"] == KEY_Z
			and Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "LIGHT")["i"] == KEY_I, "duplicate binding swaps")

	# Escape is bindable on keyboard; gamepad B cancels.
	c.begin_listen("PAUSE")
	await seconds(UiTheme.tuning().rebind_arm_delay + 0.1)
	await pad_tap(0, JOY_BUTTON_B)
	check(not c.is_listening() and Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "PAUSE")["i"] == KEY_ESCAPE,
			"pad B cancels keyboard rebind")

	# Gamepad profile for P2: bind JUMP to RT trigger via motion.
	c._player_sel.cycle(1)
	c._device_sel.cycle(-1)
	await frames(2)
	check(c.slot == 1 and c.kind == Bindings.Kind.PAD, "switched to P2 gamepad")
	c.begin_listen("JUMP")
	await seconds(UiTheme.tuning().rebind_arm_delay + 0.1)
	var m := InputEventJoypadMotion.new()
	m.device = 1
	m.axis = JOY_AXIS_TRIGGER_LEFT
	m.axis_value = 1.0
	Input.parse_input_event(m)
	await frames(2)
	m = m.duplicate()
	m.axis_value = 0.0
	Input.parse_input_event(m)
	await frames(2)
	check(Bindings.get_binding(1, Bindings.Kind.PAD, "JUMP") == {"t": "axis", "i": JOY_AXIS_TRIGGER_LEFT, "s": 1}
			and Bindings.get_binding(1, Bindings.Kind.PAD, "CHARGE")["i"] == JOY_BUTTON_A, "pad trigger bind + swap")

	# Timeout cancels.
	c.begin_listen("DASH")
	await seconds(UiTheme.tuning().rebind_timeout_seconds + 0.2)
	check(not c.is_listening(), "listening times out")

	for s in Bindings.SLOT_COUNT:
		Bindings.reset_defaults(s)
	check(Bindings.get_binding(0, Bindings.Kind.KEYBOARD, "LIGHT")["i"] == KEY_J, "defaults restored")
	c.queue_free()
	await frames(2)


func _test_controls_overlay() -> void:
	get_tree().paused = true
	var cs := ControlsScreen.open_overlay(self)
	var closed := [false]
	cs.closed.connect(func() -> void: closed[0] = true)
	await frames(3)
	check(get_viewport().gui_get_focus_owner() == cs._player_sel, "overlay gets focus while paused")
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(3)
	check(closed[0] and not is_instance_valid(cs), "overlay closes on ui_cancel")
	get_tree().paused = false
	await frames(2)


func _test_results_screen() -> void:
	var cfg := MatchConfig.from_defaults()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		cfg.players.append(p)
	Game.last_result = {"winner_slot": 0, "wins": PackedInt32Array([2, 1]), "config": cfg}
	var r := spawn(Game.SCENE_RESULTS) as ResultsScreen
	await frames(3)
	check(r._headline.text == "PLAYER 1 WINS!", "results headline")
	check(r._tally.text.contains("2  -  1"), "results tally")
	check(get_viewport().gui_get_focus_owner() == r._rematch_btn, "results focuses Rematch")
	r.queue_free()
	Game.last_result = {}
	await frames(2)


func _test_results_screen_coop() -> void:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	var p := PlayerSlotConfig.new()
	p.slot = 0
	p.team = 0
	cfg.players.append(p)
	cfg.coop = CoopConfig.new()
	Game.last_result = {"winner_slot": 0, "wins": PackedInt32Array([1, 0]), "config": cfg}
	var r := spawn(Game.SCENE_RESULTS) as ResultsScreen
	await frames(3)
	check(r._headline.text == "STAGE CLEAR!", "co-op results: cleared headline")
	check(r._tally.text.contains("Brawl"), "co-op results summarize the run")
	check(r._rematch_btn.text == "Retry", "co-op results offer Retry")
	r.queue_free()
	await frames(2)
	check(ResultsScreen.headline_text({"winner_slot": -1, "config": cfg}) == "WIPED OUT", "wipe headline")
	check(ResultsScreen.headline_text({"winner_slot": 5, "config": cfg}) == "WIPED OUT", "an enemy slot winning = wiped")
	check(ResultsScreen.headline_text({"winner_slot": -1, "config": cfg, "cleared": true}) == "STAGE CLEAR!",
			"explicit cleared flag wins")
	Game.last_result = {}


func _test_restart_match() -> void:
	var prev := Game.current_config
	Game.current_config = null
	Game.restart_match()  # no config: must not change scene or crash
	check(Game.current_config == null, "restart_match without a config is a no-op")
	Game.current_config = prev


# --- controls.cfg safety ---------------------------------------------------------------

func _backup_cfg() -> void:
	_cfg_existed = FileAccess.file_exists(Bindings.SAVE_PATH)
	if _cfg_existed:
		_cfg_bytes = FileAccess.get_file_as_bytes(Bindings.SAVE_PATH)


func _restore_cfg() -> void:
	if _cfg_existed:
		var f := FileAccess.open(Bindings.SAVE_PATH, FileAccess.WRITE)
		f.store_buffer(_cfg_bytes)
		f.close()
	elif FileAccess.file_exists(Bindings.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Bindings.SAVE_PATH))
	# Bring the in-memory bindings back to what the user had.
	for s in Bindings.SLOT_COUNT:
		Bindings.reset_defaults(s)
	Bindings.load_from_disk()
