class_name ControlsScreen
extends Control
## Controls settings: pick Player (P1/P2) and Device (Gamepad/Keyboard), then
## select an action row to rebind it. Edits the Bindings autoload directly
## (LocalDeviceInput reads it live); "Save & Back" persists to disk.
##
## Rebinding ("Press a button..."):
##  - Input is swallowed while listening. The prompt arms only after
##    Tuning.ui.rebind_arm_delay AND once ui_accept is released, so the press
##    that opened the prompt can never bind itself.
##  - The first event that Bindings.binding_from_event() accepts for the
##    selected device kind is assigned. If another action in the same profile
##    already uses it, the two actions swap bindings.
##  - Cancel: timeout (Tuning.ui.rebind_timeout_seconds), any mouse click, or
##    a press on the *other* device type: Esc cancels while rebinding a
##    gamepad action, B/Back on any pad cancels while rebinding a keyboard
##    action. This keeps Esc bindable for keyboard profiles (it is P1's
##    default Pause key) and B bindable for gamepads.
##
## Overlay use (e.g. from the pause menu while the tree is paused):
##   var cs := ControlsScreen.open_overlay(self)
##   cs.closed.connect(_on_controls_closed)
## process_mode is ALWAYS, so it works while get_tree().paused is true.

signal closed

const SCENE_PATH := "res://scenes/menus/controls_screen.tscn"

const ACTION_NAMES := {
	"LIGHT": "Light Attack", "HEAVY": "Heavy Attack", "BLAST": "Ki Blast",
	"JUMP": "Jump", "GUARD": "Guard", "CHARGE": "Charge Ki", "SPECIAL": "Special",
	"TELEPORT": "Teleport", "DASH": "Dash", "PAUSE": "Pause",
	"MOVE_FORWARD": "Move Forward", "MOVE_BACK": "Move Back",
	"MOVE_LEFT": "Move Left", "MOVE_RIGHT": "Move Right",
	"DODGE_FORWARD": "Dodge Forward", "DODGE_BACK": "Dodge Back",
	"DODGE_LEFT": "Dodge Left", "DODGE_RIGHT": "Dodge Right",
}
const PAD_FIXED_ROWS := [
	["Move", "Left Stick / D-Pad"],
	["Dodge", "Right Stick flick"],
]

## When true, Back emits `closed` and frees this node instead of going to
## the main menu.
var as_overlay: bool = false
## Currently edited profile.
var slot: int = 0
var kind: int = Bindings.Kind.PAD

var _player_sel: OptionSelector
var _device_sel: OptionSelector
var _rows_box: VBoxContainer
var _scroll: ScrollContainer
var _reset_btn: Button
var _back_btn: Button
var _status: Label
var _row_buttons: Dictionary = {}  # action -> Button
var _row_values: Dictionary = {}  # action -> Label

var _listen_action := ""
var _listen_time := 0.0
var _armed := false


## Instantiate as an overlay on its own CanvasLayer under `parent`.
static func open_overlay(parent: Node, layer: int = 100) -> ControlsScreen:
	var cl := CanvasLayer.new()
	cl.layer = layer
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	var cs: ControlsScreen = (load(SCENE_PATH) as PackedScene).instantiate()
	cs.as_overlay = true
	cl.add_child(cs)
	cs.tree_exited.connect(cl.queue_free)
	parent.add_child(cl)
	return cs


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	if as_overlay:
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.82)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(dim)
	else:
		add_child(AnimatedBackground.new())

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 80
	col.offset_right = -80
	col.offset_top = 16
	col.offset_bottom = -16
	add_child(col)

	col.add_child(MenuHelpers.title("CONTROLS"))

	var sel_row := HBoxContainer.new()
	sel_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sel_row.add_theme_constant_override("separation", 40)
	_player_sel = MenuHelpers.selector("Player", PackedStringArray(["P1", "P2"]), slot)
	_device_sel = MenuHelpers.selector("Device", PackedStringArray(["Gamepad", "Keyboard"]),
			0 if kind == Bindings.Kind.PAD else 1)
	_player_sel.value_changed.connect(func(i: int) -> void:
		slot = i
		_rebuild_rows())
	_device_sel.value_changed.connect(func(i: int) -> void:
		kind = Bindings.Kind.PAD if i == 0 else Bindings.Kind.KEYBOARD
		_rebuild_rows())
	sel_row.add_child(_player_sel)
	sel_row.add_child(_device_sel)
	col.add_child(sel_row)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(panel)
	_scroll = ScrollContainer.new()
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 8)
	_scroll.add_child(_rows_box)

	_status = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_status.add_theme_font_size_override("font_size", UiTheme.tuning().font_body)
	col.add_child(_status)

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 40)
	_reset_btn = MenuHelpers.button("Reset to defaults", _on_reset)
	_back_btn = MenuHelpers.button("Save & Back", save_and_back)
	bottom.add_child(_reset_btn)
	bottom.add_child(_back_btn)
	col.add_child(bottom)

	_rebuild_rows()
	_player_sel.grab_focus.call_deferred()


func _rebuild_rows() -> void:
	cancel_listen()
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	_row_buttons.clear()
	_row_values.clear()

	if kind == Bindings.Kind.PAD:
		for fr in PAD_FIXED_ROWS:
			_rows_box.add_child(_make_row(fr[0], fr[1] + "   (fixed)", false))

	for action in Bindings.actions_for(kind):
		var row := _make_row(ACTION_NAMES.get(action, String(action).capitalize()), "", true)
		var btn := row as Button
		btn.pressed.connect(begin_listen.bind(action))
		_row_buttons[action] = btn
		_row_values[action] = row.get_meta("value_label")
		_rows_box.add_child(row)
	_update_values()
	_relink_focus()
	_set_status_idle()


## Row = Button (focusable) or Panel (fixed) holding "Name ........ Binding".
func _make_row(name_text: String, value_text: String, focusable: bool) -> Control:
	var u := UiTheme.tuning()
	var row: Control
	if focusable:
		var b := Button.new()
		b.theme_type_variation = &"RowButton"
		b.custom_minimum_size = Vector2(0, 46)
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(func() -> void: MenuHelpers.punch(b))
		row = b
	else:
		row = PanelContainer.new()
		row.custom_minimum_size = Vector2(0, 46)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(u.color_blue_dark, 0.5)
		sb.set_corner_radius_all(u.corner_radius)
		row.add_theme_stylebox_override("panel", sb)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hb := HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 30
	hb.offset_right = -30
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := MenuHelpers.label(name_text)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var value_label := MenuHelpers.label(value_text, &"", HORIZONTAL_ALIGNMENT_RIGHT)
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_label.add_theme_color_override("font_color", u.color_orange_light if focusable else u.color_text_dim)
	if not focusable:
		name_label.add_theme_color_override("font_color", u.color_text_dim)
	hb.add_child(name_label)
	hb.add_child(value_label)
	row.add_child(hb)
	row.set_meta("value_label", value_label)
	return row


func _relink_focus() -> void:
	var chain: Array = [_player_sel, _device_sel]
	for action in _row_buttons:
		chain.append(_row_buttons[action])
	chain.append(_reset_btn)
	chain.append(_back_btn)
	MenuHelpers.link_vertical(chain)
	# Selectors use left/right to cycle; bottom buttons move between each other.
	_reset_btn.focus_neighbor_right = _reset_btn.get_path_to(_back_btn)
	_reset_btn.focus_neighbor_left = _reset_btn.get_path_to(_back_btn)
	_back_btn.focus_neighbor_left = _back_btn.get_path_to(_reset_btn)
	_back_btn.focus_neighbor_right = _back_btn.get_path_to(_reset_btn)


func _update_values() -> void:
	for action in _row_values:
		var l: Label = _row_values[action]
		if action == _listen_action:
			l.text = "Press a button..."
		else:
			l.text = Bindings.binding_label(Bindings.get_binding(slot, kind, action))


func _set_status_idle(extra: String = "") -> void:
	var t := "Select an action to rebind  -  Left/Right on Player/Device to switch profile"
	_status.text = extra if extra != "" else t


# --- Listening -----------------------------------------------------------------

func is_listening() -> bool:
	return _listen_action != ""


func begin_listen(action: String) -> void:
	_listen_action = action
	_listen_time = 0.0
	_armed = false
	_update_values()
	_status_listen()


func cancel_listen() -> void:
	if not is_listening():
		return
	_listen_action = ""
	_update_values()
	_set_status_idle("Cancelled.")


func _status_listen() -> void:
	var u := UiTheme.tuning()
	var left := ceili(maxf(u.rebind_timeout_seconds - _listen_time, 0.0))
	var cancel_hint := "Esc" if kind == Bindings.Kind.PAD else "B on a gamepad"
	var what := "a gamepad button or trigger" if kind == Bindings.Kind.PAD else "a key"
	_status.text = "%s:  press %s  (%s / click to cancel - %d)" % [
			ACTION_NAMES.get(_listen_action, _listen_action), what, cancel_hint, left]


func _process(delta: float) -> void:
	if not is_listening():
		return
	var u := UiTheme.tuning()
	_listen_time += delta
	if not _armed and _listen_time >= u.rebind_arm_delay and not Input.is_action_pressed("ui_accept"):
		_armed = true
	if _listen_time >= u.rebind_timeout_seconds:
		cancel_listen()
		return
	_status_listen()


func _input(event: InputEvent) -> void:
	if not is_listening():
		return
	# Swallow everything while listening so the GUI never sees it.
	get_viewport().set_input_as_handled()
	if not _armed:
		return
	if event is InputEventMouseButton and event.pressed:
		cancel_listen()
		return
	if kind == Bindings.Kind.PAD and event is InputEventKey and event.pressed \
			and (event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE):
		cancel_listen()
		return
	if kind == Bindings.Kind.KEYBOARD and event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_B, JOY_BUTTON_BACK]:
		cancel_listen()
		return
	var b := Bindings.binding_from_event(event, kind)
	if b.is_empty():
		return
	assign(_listen_action, b)


## Assign `b` to `action` in the current profile, swapping with any other
## action that already uses it.
func assign(action: String, b: Dictionary) -> void:
	var old := Bindings.get_binding(slot, kind, action)
	var swapped := ""
	for other in Bindings.actions_for(kind):
		if other != action and Bindings.get_binding(slot, kind, other) == b:
			Bindings.set_binding(slot, kind, other, old)
			swapped = other
	Bindings.set_binding(slot, kind, action, b)
	_listen_action = ""
	_update_values()
	var msg := "%s = %s" % [ACTION_NAMES.get(action, action), Bindings.binding_label(b)]
	if swapped != "":
		msg += "   (swapped with %s)" % ACTION_NAMES.get(swapped, swapped)
	if kind == Bindings.Kind.KEYBOARD:
		var other_slot := 1 - slot
		for a in Bindings.actions_for(kind):
			if Bindings.get_binding(other_slot, kind, a) == b:
				msg += "   WARNING: P%d keyboard also uses it (%s)" % [other_slot + 1, ACTION_NAMES.get(a, a)]
				break
	_set_status_idle(msg)
	if _row_buttons.has(action):
		(_row_buttons[action] as Button).grab_focus()


# --- Buttons ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if is_listening():
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		save_and_back()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		get_viewport().set_input_as_handled()
		_player_sel.grab_focus()


func _on_reset() -> void:
	cancel_listen()
	Bindings.reset_defaults(slot)
	_update_values()
	_set_status_idle("P%d controls reset to defaults (gamepad and keyboard)." % (slot + 1))


func save_and_back() -> void:
	cancel_listen()
	Bindings.save_to_disk()
	if as_overlay:
		closed.emit()
		queue_free()
	else:
		Game.goto(Game.SCENE_MAIN_MENU)
