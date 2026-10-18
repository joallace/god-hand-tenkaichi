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
	await _test_controls_screen()
	await _test_controls_overlay()
	await _test_results_screen()
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
	var m := spawn(Game.SCENE_MAIN_MENU) as Control
	await frames(5)
	var focus := get_viewport().gui_get_focus_owner()
	check(focus is Button and (focus as Button).text.begins_with("P1 vs P2"), "main menu focuses first button")
	# Wrap: up from the first enabled button goes to Quit.
	var ev := InputEventAction.new()
	ev.action = "ui_up"
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	focus = get_viewport().gui_get_focus_owner()
	check(focus is Button and (focus as Button).text == "Quit", "main menu focus wraps to Quit")
	m.call("_on_how_to_play")
	await frames(3)
	focus = get_viewport().gui_get_focus_owner()
	check(m.get("_how_to") != null and focus is Button and (focus as Button).text == "Back", "how-to-play panel opens with focus")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	Input.parse_input_event(cancel)
	await frames(3)
	check(m.get("_how_to") == null and get_viewport().gui_get_focus_owner() is Button, "how-to-play closes, focus restored")
	m.queue_free()
	await frames(2)


func _test_join_screen() -> void:
	JoinScreen.pending_mode = MatchConfig.Mode.LOCAL_VERSUS
	var j := spawn(Game.SCENE_JOIN) as JoinScreen
	j.auto_start = false
	var requested: Array = []
	j.match_requested.connect(func(c: MatchConfig) -> void: requested.append(c))
	await frames(3)

	await pad_tap(0, JOY_BUTTON_START)
	check(j.slots[0].state == JoinScreen.SlotState.JOINED and j.slots[0].device_id == 0, "pad 0 joins slot P1")
	await pad_tap(0, JOY_BUTTON_START)  # same device: would READY, must not claim slot 2
	check(j.slots[1].state == JoinScreen.SlotState.EMPTY, "pad 0 cannot claim a second slot")
	check(j.slots[0].state == JoinScreen.SlotState.READY, "pad 0 START again readies")
	await pad_tap(0, JOY_BUTTON_B)
	check(j.slots[0].state == JoinScreen.SlotState.JOINED, "pad 0 B un-readies")

	await pad_tap(1, JOY_BUTTON_START)
	check(j.slots[1].state == JoinScreen.SlotState.JOINED and j.slots[1].device_id == 1
			and j.slots[1].device_kind == Bindings.Kind.PAD, "pad 1 joins slot P2")
	check(j.slots[0].device_id != j.slots[1].device_id, "slots have distinct devices")

	# Pad 1 leaves, keyboard takes slot 2 with layout B.
	await pad_tap(1, JOY_BUTTON_B)
	check(j.slots[1].state == JoinScreen.SlotState.EMPTY, "pad 1 B leaves")
	await key_tap(KEY_ENTER)
	check(j.slots[1].state == JoinScreen.SlotState.JOINED and j.slots[1].device_kind == Bindings.Kind.KEYBOARD,
			"Enter joins keyboard into P2")

	# Settings: P1 pad moves to Timer row and cycles to infinite.
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
	check(j.rounds_to_win == mini(Tuning.match_rules.rounds_to_win + 1, 5), "rounds to win changed by P1")
	await pad_tap(0, JOY_BUTTON_DPAD_DOWN)
	var opts := Tuning.match_rules.round_time_options
	var inf_idx := opts.find(0)
	var guard := 0
	while j.time_index != inf_idx and guard < 10:
		await pad_tap(0, JOY_BUTTON_DPAD_RIGHT)
		guard += 1
	check(j.time_index == inf_idx, "timer can be set to infinite")

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
			and Bindings.get_binding(1, Bindings.Kind.PAD, "TELEPORT")["i"] == JOY_BUTTON_A, "pad trigger bind + swap")

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
