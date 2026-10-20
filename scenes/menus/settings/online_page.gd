class_name OnlinePage
extends SettingsPage
## Settings > Online (SPEC_ONLINE.md §10.1): profile name, input delay
## (Auto / fixed frames), host port and the debug net overlay. Edits
## Net.settings (OnlineSettings) directly; every valid change is saved to
## user://online.cfg, an invalid name is flagged on the status line and not
## stored. The port is a stepper (pad-friendly; digits can be typed).
##
## `locked` (opened from the in-match pause menu): name, delay and port are
## read-only because the session already uses them; the net overlay stays
## editable.

## Lowest port the host-port stepper offers (below are privileged/well-known).
const PORT_MIN := 1024
const DELAY_AUTO_LABEL := "Auto"
const LOCKED_HELP := "Can't be changed during a match."

var locked := false
var name_edit: LineEdit
var delay_sel: OptionSelector
var port_step: NumberStepper
var overlay_sel: OptionSelector


func _init() -> void:
	super()
	title = "ONLINE"


func _ready() -> void:
	var u := UiTheme.tuning()
	var s := Net.settings

	name_edit = LineEdit.new()
	name_edit.text = s.player_name
	name_edit.placeholder_text = "Profile name"
	name_edit.max_length = Tuning.net.name_max_len
	name_edit.select_all_on_focus = true
	name_edit.custom_minimum_size = Vector2(u.online_field_width, u.button_min_size.y)
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(set_name_text)
	var name_row := HBoxContainer.new()
	var l := MenuHelpers.label("Profile name")
	l.custom_minimum_size.x = u.online_label_width
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(l)
	name_row.add_child(name_edit)
	add_row(name_row)
	name_edit.set_meta(&"help", LOCKED_HELP if locked else
			"Shown to other players online. Type with a keyboard.")

	var delays := PackedStringArray([DELAY_AUTO_LABEL])
	for d in Tuning.net.input_delay_max + 1:
		delays.append("%d" % d)
	delay_sel = MenuHelpers.selector("Input delay", delays, 0 if s.is_auto_delay() else s.input_delay + 1)
	delay_sel.value_changed.connect(func(i: int) -> void:
		Net.settings.set_input_delay(OnlineSettings.DELAY_AUTO if i == 0 else i - 1)
		_save())
	add_row(delay_sel, LOCKED_HELP if locked else
			"Frames of input delay online. Auto picks it from the connection's ping.")

	var default_port := Tuning.net.default_port
	port_step = NumberStepper.new().setup("Host port (UDP)", PORT_MIN, OnlineSettings.MAX_PORT,
			s.host_port(), 1, u.port_step_fast)
	port_step.labels = {default_port: "%d (default)" % default_port}
	port_step.custom_minimum_size.y = u.button_min_size.y
	port_step.value_changed.connect(set_port)
	add_row(port_step, LOCKED_HELP if locked else
			"UDP port used when you host. Hold left/right to change faster, or type a number.")

	overlay_sel = MenuHelpers.selector("Net stats overlay", PackedStringArray(["Off", "On"]),
			1 if s.net_overlay else 0)
	overlay_sel.value_changed.connect(func(i: int) -> void:
		Net.settings.net_overlay = i == 1
		_save())
	add_row(overlay_sel, "Ping, rollback and delay readout during online matches (F3 toggles it too).")

	var reset := add_reset_row("Online", _reset)
	reset.disabled = locked
	reset.focus_mode = Control.FOCUS_NONE if locked else Control.FOCUS_ALL
	name_edit.editable = not locked
	delay_sel.disabled = locked
	port_step.disabled = locked
	relink()


func relink() -> void:
	MenuHelpers.link_vertical([name_edit] + rows.get_children().slice(1))


func focus_first() -> void:
	name_edit.grab_focus.call_deferred()


## Validate and store a profile name; returns whether it was accepted.
func set_name_text(t: String) -> bool:
	if locked:
		return false
	if not Net.settings.set_player_name(t):
		status.emit("Invalid name: 1-%d printable characters" % Tuning.net.name_max_len, true)
		return false
	_save()
	return true


## Store the host port (the default port is stored as PORT_DEFAULT).
func set_port(p: int) -> void:
	if locked:
		return
	Net.settings.set_port(OnlineSettings.PORT_DEFAULT if p == Tuning.net.default_port else p)
	_save()


func _save() -> void:
	var failed := Net.settings.save() != OK
	status.emit("Could not save settings" if failed else "", failed)


func _reset() -> void:
	Net.settings.set_input_delay(OnlineSettings.DELAY_AUTO)
	Net.settings.set_port(OnlineSettings.PORT_DEFAULT)
	Net.settings.net_overlay = false
	Net.settings.save()
	delay_sel.index = 0
	port_step.value = Net.settings.host_port()
	overlay_sel.index = 0


func is_busy() -> bool:
	return super() or port_step.is_typing()


func on_close() -> void:
	Net.settings.save()
