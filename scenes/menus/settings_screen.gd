class_name SettingsScreen
extends Control
## Settings (SPEC_ONLINE.md §10.1): profile name, input delay (Auto / fixed
## frames), host port and the debug net overlay. Edits Net.settings
## (OnlineSettings) directly; every valid change is saved to
## user://online.cfg, invalid text is flagged on the status line and not
## stored. ui_cancel / Back returns to the main menu.

## Lowest port the host-port field accepts (below are privileged/well-known).
const PORT_MIN := 1024
const DELAY_AUTO_LABEL := "Auto"

var name_edit: LineEdit
var delay_sel: OptionSelector
var port_edit: LineEdit
var overlay_sel: OptionSelector
var status: Label
var back_btn: Button


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var s := Net.settings

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", u.online_separation)
	col.add_child(MenuHelpers.title("SETTINGS"))

	name_edit = _field(s.player_name, "Profile name")
	name_edit.max_length = Tuning.net.name_max_len
	name_edit.text_changed.connect(set_name_text)
	port_edit = _field("" if s.port == OnlineSettings.PORT_DEFAULT else str(s.port),
			"%d (default)" % Tuning.net.default_port)
	port_edit.max_length = str(OnlineSettings.MAX_PORT).length()
	port_edit.text_changed.connect(set_port_text)

	var delays := PackedStringArray([DELAY_AUTO_LABEL])
	for d in Tuning.net.input_delay_max + 1:
		delays.append("%d" % d)
	delay_sel = MenuHelpers.selector("Input delay", delays, 0 if s.is_auto_delay() else s.input_delay + 1)
	delay_sel.value_changed.connect(func(i: int) -> void:
		Net.settings.set_input_delay(OnlineSettings.DELAY_AUTO if i == 0 else i - 1)
		_save())
	overlay_sel = MenuHelpers.selector("Net stats overlay", PackedStringArray(["Off", "On"]),
			1 if s.net_overlay else 0)
	overlay_sel.value_changed.connect(func(i: int) -> void:
		Net.settings.net_overlay = i == 1
		_save())
	back_btn = MenuHelpers.button("Back", back)

	var name_row := _row("Profile name", name_edit)
	var port_row := _row("Host port (UDP)", port_edit)
	var list := MenuHelpers.vlist([name_row, delay_sel, port_row, overlay_sel, back_btn])
	col.add_child(list)
	MenuHelpers.link_vertical([name_edit, delay_sel, port_edit, overlay_sel, back_btn])

	status = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(status)
	col.add_child(MenuHelpers.label("[A]/[Enter] edit / select     [B]/[Esc] back", &"HintLabel",
			HORIZONTAL_ALIGNMENT_CENTER))
	add_child(MenuHelpers.centered(col))
	_show_status("")
	name_edit.grab_focus.call_deferred()


func _field(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(UiTheme.tuning().online_field_width, UiTheme.tuning().button_min_size.y)
	e.select_all_on_focus = true
	return e


func _row(label_text: String, field: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := MenuHelpers.label(label_text)
	l.custom_minimum_size.x = UiTheme.tuning().online_label_width
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	row.add_child(field)
	return row


## Validate and store a profile name; returns whether it was accepted.
func set_name_text(t: String) -> bool:
	if not Net.settings.set_player_name(t):
		_show_status("Invalid name: 1-%d printable characters" % Tuning.net.name_max_len, true)
		return false
	_save()
	return true


## Validate and store the host port ("" = default); returns whether it was
## accepted.
func set_port_text(t: String) -> bool:
	var s := t.strip_edges()
	if s.is_empty():
		Net.settings.set_port(OnlineSettings.PORT_DEFAULT)
	elif s.is_valid_int() and s.to_int() >= PORT_MIN and s.to_int() <= OnlineSettings.MAX_PORT:
		var p := s.to_int()
		Net.settings.set_port(OnlineSettings.PORT_DEFAULT if p == Tuning.net.default_port else p)
	else:
		_show_status("Invalid port: %d-%d (empty = %d)" % [PORT_MIN, OnlineSettings.MAX_PORT,
				Tuning.net.default_port], true)
		return false
	_save()
	return true


func _save() -> void:
	if Net.settings.save() != OK:
		_show_status("Could not save settings", true)
	else:
		_show_status("")


func _show_status(text: String, error := false) -> void:
	var u := UiTheme.tuning()
	status.text = text if not text.is_empty() else "Name and port are typed; the name is shown to other players online."
	status.add_theme_color_override("font_color", u.color_error if error else u.color_text_dim)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		back()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		get_viewport().set_input_as_handled()
		name_edit.grab_focus()


## Save (fields hold only valid values in Net.settings) and leave.
func back() -> void:
	Net.settings.save()
	Game.goto(Game.SCENE_MAIN_MENU)
