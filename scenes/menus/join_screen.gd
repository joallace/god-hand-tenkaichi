class_name JoinScreen
extends Control
## Join / setup screen. Each physical device claims a slot, picks a character
## and readies up; when every slot is ready a MatchConfig is built and handed
## to Game.start_match().
##
## Input is read per *device* in _input (event.device), not through global
## ui_* actions, so two pads never steer the same slot.
##
## Gamepad (unjoined): START or A joins the next free slot. B with nobody
##   joined -> main menu.
## Gamepad (joined):   D-pad / left stick up-down picks a row (Character,
##   Rounds, Timer), left-right changes it; A/START = ready; B = un-ready, then
##   leave.
## Keyboard: ENTER joins a keyboard player into the next free slot; that slot
##   number picks the Bindings keyboard layout (slot 0 = A/WASD, slot 1 =
##   B/arrows+numpad). Joined keyboard players navigate with their layout's
##   MOVE keys, ready with their LIGHT or JUMP key (or ENTER once all slots
##   are filled) and back out with their PAUSE key (or ESC). While only one
##   keyboard player is joined, arrow keys also navigate for it.
##
## FUTURE MODES (hooks): the screen is driven by `slot_types`.
##   VERSUS_CPU: slot_types = [HUMAN, CPU]. CPU slots are pre-joined & ready
##     (see _configure_for_mode); TODO let P1 move a cursor onto the CPU panel
##     to pick its character / cpu_level.
##   ONLINE: slot_types = [HUMAN, REMOTE]. A lobby/network layer should call
##     set_remote_slot(slot, peer_id, character_id, ready) as messages arrive;
##     only HUMAN slots accept local devices. _build_config() already maps
##     REMOTE -> PlayerSlotConfig.InputKind.NETWORK.

## Emitted with the finished config right before the match starts.
signal match_requested(config: MatchConfig)

enum SlotType { HUMAN, CPU, REMOTE }
enum SlotState { EMPTY, JOINED, READY }
enum Cmd { UP, DOWN, LEFT, RIGHT, CONFIRM, BACK }
enum Row { CHARACTER, ROUNDS, TIMER }
const ROW_COUNT := 3

## Set before Game.goto(Game.SCENE_JOIN) to choose which mode this screen sets up.
static var pending_mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS
## Settings/characters remembered across visits (Change Setup from results).
static var _memory: Dictionary = {}

class Slot:
	var type: int = SlotType.HUMAN
	var state: int = SlotState.EMPTY
	var device_kind: int = Bindings.Kind.PAD
	var device_id: int = -1
	var char_index: int = 0
	var cursor: int = Row.CHARACTER
	var peer_id: int = 0
	var join_order: int = 0

var mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS
var slots: Array[Slot] = []
var rounds_to_win: int = 2
var time_index: int = 0
## Tests set this false to inspect match_requested without changing scene.
var auto_start: bool = true

var _time_options: PackedInt32Array
var _countdown := 0.0
var _started := false
var _join_counter := 0
var _stick_dir: Dictionary = {}  # device -> Vector2i
var _blink := 0.0

# UI refs per slot
var _ui: Array[Dictionary] = []
var _rounds_label: Label
var _timer_label: Label
var _status_label: Label


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	var rules: MatchTuning = Tuning.match_rules
	_time_options = rules.round_time_options
	if _time_options.is_empty():
		_time_options = PackedInt32Array([rules.round_time_seconds])
	rounds_to_win = clampi(rules.rounds_to_win, 1, 5)
	time_index = maxi(_time_options.find(rules.round_time_seconds), 0)
	mode = pending_mode
	_configure_for_mode()
	_restore_memory()
	_build_ui()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh()


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.disconnect(_on_joy_connection_changed)


## Slot layout per mode. This is the main hook for VERSUS_CPU / ONLINE.
func _configure_for_mode() -> void:
	var types: Array[int]
	match mode:
		MatchConfig.Mode.VERSUS_CPU:
			types = [SlotType.HUMAN, SlotType.CPU]
		MatchConfig.Mode.ONLINE:
			types = [SlotType.HUMAN, SlotType.REMOTE]
		_:
			types = [SlotType.HUMAN, SlotType.HUMAN]
	slots.clear()
	for t in types:
		var s := Slot.new()
		s.type = t
		if t == SlotType.CPU:
			s.state = SlotState.READY  # TODO(VERSUS_CPU): CPU character pick.
		slots.append(s)


## ONLINE hook: called by the lobby layer for the remote player's slot.
func set_remote_slot(slot: int, peer_id: int, character_id: StringName, ready: bool) -> void:
	if slot < 0 or slot >= slots.size() or slots[slot].type != SlotType.REMOTE:
		return
	var s := slots[slot]
	s.peer_id = peer_id
	s.char_index = maxi(MenuHelpers.character_ids().find(character_id), 0)
	s.state = SlotState.READY if ready else SlotState.JOINED
	_refresh()


# --- Input ---------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _started:
		return
	if event is InputEventJoypadButton:
		if event.pressed:
			_on_pad_button(event)
	elif event is InputEventJoypadMotion:
		_on_pad_motion(event)
	elif event is InputEventKey:
		if event.pressed and not event.echo:
			_on_key(event)
	else:
		return
	get_viewport().set_input_as_handled()


func _on_pad_button(e: InputEventJoypadButton) -> void:
	var idx := slot_for_device(Bindings.Kind.PAD, e.device)
	if idx < 0:
		match e.button_index:
			JOY_BUTTON_START, JOY_BUTTON_A:
				join(Bindings.Kind.PAD, e.device)
			JOY_BUTTON_B, JOY_BUTTON_BACK:
				if nobody_joined():
					_back_to_menu()
		return
	match e.button_index:
		JOY_BUTTON_A, JOY_BUTTON_START:
			_command(idx, Cmd.CONFIRM)
		JOY_BUTTON_B, JOY_BUTTON_BACK:
			_command(idx, Cmd.BACK)
		JOY_BUTTON_DPAD_UP:
			_command(idx, Cmd.UP)
		JOY_BUTTON_DPAD_DOWN:
			_command(idx, Cmd.DOWN)
		JOY_BUTTON_DPAD_LEFT:
			_command(idx, Cmd.LEFT)
		JOY_BUTTON_DPAD_RIGHT:
			_command(idx, Cmd.RIGHT)


func _on_pad_motion(e: InputEventJoypadMotion) -> void:
	if e.axis != JOY_AXIS_LEFT_X and e.axis != JOY_AXIS_LEFT_Y:
		return
	var idx := slot_for_device(Bindings.Kind.PAD, e.device)
	if idx < 0:
		return
	var th := UiTheme.tuning().stick_nav_threshold
	var v := Vector2(Input.get_joy_axis(e.device, JOY_AXIS_LEFT_X), Input.get_joy_axis(e.device, JOY_AXIS_LEFT_Y))
	if e.axis == JOY_AXIS_LEFT_X:
		v.x = e.axis_value
	else:
		v.y = e.axis_value
	var dir := Vector2i.ZERO
	if absf(v.x) >= th and absf(v.x) >= absf(v.y):
		dir.x = signi(roundi(signf(v.x)))
	elif absf(v.y) >= th:
		dir.y = signi(roundi(signf(v.y)))
	var prev: Vector2i = _stick_dir.get(e.device, Vector2i.ZERO)
	if dir == prev:
		return
	_stick_dir[e.device] = dir
	if dir.x < 0:
		_command(idx, Cmd.LEFT)
	elif dir.x > 0:
		_command(idx, Cmd.RIGHT)
	elif dir.y < 0:
		_command(idx, Cmd.UP)
	elif dir.y > 0:
		_command(idx, Cmd.DOWN)


const _KEY_LAYOUT_CMDS := {
	"MOVE_FORWARD": Cmd.UP, "MOVE_BACK": Cmd.DOWN,
	"MOVE_LEFT": Cmd.LEFT, "MOVE_RIGHT": Cmd.RIGHT,
	"LIGHT": Cmd.CONFIRM, "JUMP": Cmd.CONFIRM, "PAUSE": Cmd.BACK,
}


func _on_key(e: InputEventKey) -> void:
	var b := Bindings.binding_from_event(e, Bindings.Kind.KEYBOARD)
	if b.is_empty():
		return
	var code: int = b["i"]
	var kb := keyboard_slots()
	# 1) Per-layout keys of each joined keyboard player.
	for idx in kb:
		for action in _KEY_LAYOUT_CMDS:
			if Bindings.get_binding(idx, Bindings.Kind.KEYBOARD, action) == b:
				_command(idx, _KEY_LAYOUT_CMDS[action])
				return
	# 2) Generic keys.
	match code:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if first_free_slot() >= 0:
				join(Bindings.Kind.KEYBOARD, -1)
			else:
				for idx in kb:
					if slots[idx].state == SlotState.JOINED:
						_command(idx, Cmd.CONFIRM)
						return
		KEY_ESCAPE, KEY_BACKSPACE:
			if not kb.is_empty():
				var last := kb[0]
				for idx in kb:
					if slots[idx].join_order > slots[last].join_order:
						last = idx
				_command(last, Cmd.BACK)
			elif nobody_joined():
				_back_to_menu()
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
			if kb.size() == 1:
				var cmd: int = {KEY_UP: Cmd.UP, KEY_DOWN: Cmd.DOWN, KEY_LEFT: Cmd.LEFT, KEY_RIGHT: Cmd.RIGHT}[code]
				_command(kb[0], cmd)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if not connected:
		var idx := slot_for_device(Bindings.Kind.PAD, device)
		if idx >= 0:
			leave(idx)
	_stick_dir.erase(device)
	_refresh()


# --- Slot logic ----------------------------------------------------------------

func slot_for_device(kind: int, device: int) -> int:
	if kind == Bindings.Kind.KEYBOARD:
		return -1  # the keyboard may own several slots (one per layout)
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY \
				and s.device_kind == kind and s.device_id == device:
			return i
	return -1


func keyboard_slots() -> Array[int]:
	var out: Array[int] = []
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY and s.device_kind == Bindings.Kind.KEYBOARD:
			out.append(i)
	return out


func first_free_slot() -> int:
	for i in slots.size():
		if slots[i].type == SlotType.HUMAN and slots[i].state == SlotState.EMPTY:
			return i
	return -1


func nobody_joined() -> bool:
	for s in slots:
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY:
			return false
	return true


## Claim the next free HUMAN slot for a device. Returns the slot or -1.
func join(kind: int, device: int) -> int:
	if kind == Bindings.Kind.PAD and slot_for_device(kind, device) >= 0:
		return -1
	var idx := first_free_slot()
	if idx < 0:
		return -1
	var s := slots[idx]
	s.state = SlotState.JOINED
	s.device_kind = kind
	s.device_id = device if kind == Bindings.Kind.PAD else -1
	s.cursor = Row.CHARACTER
	_join_counter += 1
	s.join_order = _join_counter
	_punch_panel(idx)
	_refresh()
	return idx


func leave(idx: int) -> void:
	var s := slots[idx]
	if s.type != SlotType.HUMAN:
		return
	s.state = SlotState.EMPTY
	s.device_id = -1
	_refresh()


func _command(idx: int, cmd: int) -> void:
	var s := slots[idx]
	match s.state:
		SlotState.READY:
			if cmd == Cmd.BACK:
				s.state = SlotState.JOINED
		SlotState.JOINED:
			match cmd:
				Cmd.UP:
					s.cursor = posmod(s.cursor - 1, ROW_COUNT)
				Cmd.DOWN:
					s.cursor = posmod(s.cursor + 1, ROW_COUNT)
				Cmd.LEFT:
					_change_row(s, -1)
				Cmd.RIGHT:
					_change_row(s, 1)
				Cmd.CONFIRM:
					s.state = SlotState.READY
					_punch_panel(idx)
				Cmd.BACK:
					leave(idx)
					return
	_refresh()


func _change_row(s: Slot, dir: int) -> void:
	match s.cursor:
		Row.CHARACTER:
			var n := MenuHelpers.character_ids().size()
			s.char_index = posmod(s.char_index + dir, maxi(n, 1))
		Row.ROUNDS:
			rounds_to_win = clampi(rounds_to_win + dir, 1, 5)
		Row.TIMER:
			time_index = posmod(time_index + dir, _time_options.size())


func all_ready() -> bool:
	for s in slots:
		if s.state != SlotState.READY:
			return false
	return not slots.is_empty()


func _process(delta: float) -> void:
	_blink += delta
	if _started:
		return
	if all_ready():
		_countdown -= delta
		if _countdown <= 0.0:
			_start()
			return
	else:
		_countdown = UiTheme.tuning().join_start_delay
	_refresh_status()
	for i in _ui.size():
		if slots[i].state == SlotState.EMPTY:
			(_ui[i]["state"] as Label).modulate.a = 0.55 + 0.45 * absf(sin(_blink * 3.0))
		else:
			(_ui[i]["state"] as Label).modulate.a = 1.0


func build_config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(mode)
	cfg.rounds_to_win = rounds_to_win
	cfg.round_time_seconds = _time_options[time_index]
	var ids := MenuHelpers.character_ids()
	for i in slots.size():
		var s := slots[i]
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = ids[s.char_index] if s.char_index < ids.size() else ids[0]
		match s.type:
			SlotType.CPU:
				p.input_kind = PlayerSlotConfig.InputKind.CPU
			SlotType.REMOTE:
				p.input_kind = PlayerSlotConfig.InputKind.NETWORK
				p.peer_id = s.peer_id
			_:
				p.input_kind = PlayerSlotConfig.InputKind.LOCAL
				p.device_kind = s.device_kind
				p.device_id = s.device_id
		cfg.players.append(p)
	return cfg


func _start() -> void:
	_started = true
	_remember()
	var cfg := build_config()
	match_requested.emit(cfg)
	if auto_start:
		Game.start_match(cfg)


func _back_to_menu() -> void:
	_remember()
	_started = true
	Game.goto(Game.SCENE_MAIN_MENU)


func _remember() -> void:
	var chars: Array[int] = []
	for s in slots:
		chars.append(s.char_index)
	_memory = {"rounds": rounds_to_win, "time": _time_options[time_index], "chars": chars}


func _restore_memory() -> void:
	if _memory.is_empty():
		return
	rounds_to_win = int(_memory.get("rounds", rounds_to_win))
	var t := _time_options.find(int(_memory.get("time", -999)))
	if t >= 0:
		time_index = t
	var chars: Array = _memory.get("chars", [])
	var n := MenuHelpers.character_ids().size()
	for i in mini(chars.size(), slots.size()):
		slots[i].char_index = clampi(int(chars[i]), 0, n - 1)


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 40
	root.offset_right = -40
	root.offset_top = 16
	root.offset_bottom = -16
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	root.add_child(MenuHelpers.title("CHOOSE YOUR FIGHTERS"))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 30)
	root.add_child(row)

	for i in slots.size():
		var ui := _build_player_panel(i, u.color_p1 if i == 0 else u.color_p2)
		_ui.append(ui)
		row.add_child(ui["panel"])
		if i == 0:
			row.add_child(_build_settings_panel())

	_status_label = MenuHelpers.label("", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	root.add_child(_status_label)
	root.add_child(MenuHelpers.label(
			"Pad: START/A join  -  D-pad/stick choose  -  A ready  -  B back/leave\n"
			+ "Keyboard: ENTER join  -  your MOVE keys choose (arrows if alone)  -  LIGHT/JUMP ready  -  PAUSE/ESC back",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))


func _build_player_panel(i: int, color: Color) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := (UiTheme.get_theme().get_stylebox("panel", "PanelContainer") as StyleBoxFlat).duplicate() as StyleBoxFlat
	sb.border_color = color
	sb.set_border_width_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(col)
	var header := MenuHelpers.title("PLAYER %d" % (i + 1), &"HeaderLabel")
	header.add_theme_color_override("font_color", color)
	col.add_child(header)
	var device := MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(device)
	var state := MenuHelpers.label("", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(state)
	var character := MenuHelpers.label("", &"", HORIZONTAL_ALIGNMENT_CENTER)
	character.add_theme_font_size_override("font_size", UiTheme.tuning().font_button)
	col.add_child(character)
	var hint := MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)
	return {"panel": panel, "device": device, "state": state, "character": character, "hint": hint, "color": color}


func _build_settings_panel() -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.custom_minimum_size.x = 420
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(col)
	col.add_child(MenuHelpers.title("MATCH RULES", &"HeaderLabel"))
	_rounds_label = MenuHelpers.label("", &"", HORIZONTAL_ALIGNMENT_CENTER)
	_timer_label = MenuHelpers.label("", &"", HORIZONTAL_ALIGNMENT_CENTER)
	for l in [_rounds_label, _timer_label]:
		l.add_theme_font_size_override("font_size", UiTheme.tuning().font_button)
		col.add_child(l)
	col.add_child(MenuHelpers.label("Any joined player:\nup/down to pick a row,\nleft/right to change it",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))
	return panel


func _cursor_tags(row: int) -> String:
	var tags: PackedStringArray = []
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor == row:
			tags.append("P%d" % (i + 1))
	return ("[%s] " % ",".join(tags)) if not tags.is_empty() else ""


func _row_color(row: int) -> Color:
	var u := UiTheme.tuning()
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor == row:
			return u.color_p1 if i == 0 else u.color_p2
	return u.color_text


func _refresh() -> void:
	if _ui.is_empty():
		return
	var u := UiTheme.tuning()
	var ids := MenuHelpers.character_ids()
	for i in slots.size():
		var s := slots[i]
		var ui := _ui[i]
		var state: Label = ui["state"]
		var device: Label = ui["device"]
		var character: Label = ui["character"]
		var hint: Label = ui["hint"]
		var cname := MenuHelpers.character_name(ids[clampi(s.char_index, 0, ids.size() - 1)])
		character.visible = s.state != SlotState.EMPTY
		match s.type:
			SlotType.CPU:
				device.text = "CPU"
			SlotType.REMOTE:
				device.text = "Online peer %d" % s.peer_id if s.peer_id != 0 else "Waiting for opponent..."
			_:
				device.text = MenuHelpers.device_label(s.device_kind, s.device_id, i) if s.state != SlotState.EMPTY else "-"
		match s.state:
			SlotState.EMPTY:
				state.text = "PRESS START\nOR ENTER"
				state.add_theme_color_override("font_color", u.color_text)
				hint.text = ""
			SlotState.JOINED:
				state.text = "CHOOSE!"
				state.add_theme_color_override("font_color", ui["color"])
				hint.text = "Press A / %s when ready" % _confirm_key_name(i)
			SlotState.READY:
				state.text = "READY!"
				state.add_theme_color_override("font_color", u.color_ready)
				hint.text = "B / %s to cancel" % _back_key_name(i)
		var on_char := s.state == SlotState.JOINED and s.cursor == Row.CHARACTER
		character.text = ("<  %s  >" % cname) if on_char else cname
		character.add_theme_color_override("font_color", ui["color"] if on_char else u.color_text)
	_rounds_label.text = "%sRounds to win  <  %d  >" % [_cursor_tags(Row.ROUNDS), rounds_to_win]
	_rounds_label.add_theme_color_override("font_color", _row_color(Row.ROUNDS))
	_timer_label.text = "%sTimer  <  %s  >" % [_cursor_tags(Row.TIMER), MenuHelpers.round_time_label(_time_options[time_index])]
	_timer_label.add_theme_color_override("font_color", _row_color(Row.TIMER))
	_refresh_status()


func _confirm_key_name(i: int) -> String:
	if slots[i].device_kind != Bindings.Kind.KEYBOARD:
		return "START"
	return Bindings.binding_label(Bindings.get_binding(i, Bindings.Kind.KEYBOARD, "LIGHT"))


func _back_key_name(i: int) -> String:
	if slots[i].device_kind != Bindings.Kind.KEYBOARD:
		return "BACK"
	return Bindings.binding_label(Bindings.get_binding(i, Bindings.Kind.KEYBOARD, "PAUSE"))


func _refresh_status() -> void:
	if _status_label == null:
		return
	if _started:
		_status_label.text = "FIGHT!"
	elif all_ready():
		_status_label.text = "GET READY... %d" % ceili(maxf(_countdown, 0.0))
	elif nobody_joined():
		_status_label.text = "B / ESC: back to menu"
	else:
		_status_label.text = ""


func _punch_panel(idx: int) -> void:
	if idx < _ui.size():
		MenuHelpers.punch(_ui[idx]["panel"])
