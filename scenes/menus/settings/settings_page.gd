class_name SettingsPage
extends ScrollContainer
## Base for a Settings tab (SettingsScreen): a scrolling, centered column of
## option rows with wrap-around vertical focus. Rows may carry a "help" meta
## string, shown on the screen's status line while focused.
##
## Page contract (also met by the embedded ControlsScreen): `title`,
## focus_first(), is_busy() (input belongs to the page: rebinding, a prompt,
## typing), flush() -> bool (true = something pending was started and the
## screen must stay open, e.g. a display change awaiting confirmation),
## on_close() (persist), and the `status` signal for messages/errors.

signal status(text: String, error: bool)

var title := ""
var rows: VBoxContainer
var _prompt: ConfirmPrompt


func _init() -> void:
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	process_mode = Node.PROCESS_MODE_ALWAYS
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(center)
	rows = VBoxContainer.new()
	rows.add_theme_constant_override("separation", UiTheme.tuning().list_separation)
	center.add_child(rows)


## Add a row (fixed width) with optional help text; returns it.
func add_row(c: Control, help := "") -> Control:
	c.custom_minimum_size.x = UiTheme.tuning().settings_row_width
	if help != "":
		c.set_meta(&"help", help)
	rows.add_child(c)
	return c


## Link vertical focus across the focusable rows (call after building and
## whenever rows change enabled state).
func relink() -> void:
	MenuHelpers.link_vertical(rows.get_children())


func focus_first() -> void:
	MenuHelpers.focus_first(rows)


func is_busy() -> bool:
	return _prompt != null and is_instance_valid(_prompt)


func flush() -> bool:
	return false


func on_close() -> void:
	pass


## "Reset to defaults" row with a confirm prompt; `on_confirm` does the reset.
func add_reset_row(what: String, on_confirm: Callable) -> Button:
	var b := MenuHelpers.button("Reset to defaults")
	b.pressed.connect(func() -> void:
		_prompt = ConfirmPrompt.open(_prompt_parent(), "Reset %s settings to defaults?" % what, "Reset", "Cancel")
		_prompt.resolved.connect(func(yes: bool) -> void:
			_prompt = null
			if yes:
				on_confirm.call()
				status.emit("%s settings reset to defaults." % what, false)))
	add_row(b, "Restore every %s setting on this page." % what.to_lower())
	return b


## Prompts cover the whole screen, not just the page.
func _prompt_parent() -> Node:
	var p := get_parent()
	while p != null and not (p is SettingsScreen):
		p = p.get_parent()
	return p if p != null else self


static func percent_labels(steps: PackedFloat32Array) -> PackedStringArray:
	var out := PackedStringArray()
	for s in steps:
		out.append("%d%%" % roundi(s * 100.0))
	return out
