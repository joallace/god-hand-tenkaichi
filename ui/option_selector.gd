class_name OptionSelector
extends Button
## Focusable "Label   <  value  >" row. ui_left / ui_right (d-pad, stick,
## arrows) cycle values while focused; ui_accept cycles forward.

signal value_changed(index: int)

var label_text: String = ""
var options: PackedStringArray = PackedStringArray()
var index: int = 0:
	set(v):
		index = v
		_refresh()
## Wrap past the ends instead of clamping.
var wrap_around: bool = true


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	alignment = HORIZONTAL_ALIGNMENT_CENTER
	pressed.connect(func() -> void: cycle(1))
	_refresh()


func setup(p_label: String, p_options: PackedStringArray, p_index: int = 0) -> OptionSelector:
	label_text = p_label
	options = p_options
	index = clampi(p_index, 0, maxi(options.size() - 1, 0))
	return self


func current() -> String:
	return options[index] if index < options.size() else ""


func cycle(dir: int) -> void:
	if options.is_empty() or disabled:
		return
	var n := index + dir
	if wrap_around:
		n = posmod(n, options.size())
	else:
		n = clampi(n, 0, options.size() - 1)
	if n == index:
		return
	index = n
	MenuHelpers.punch(self)
	value_changed.emit(index)


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		cycle(-1)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		cycle(1)
		accept_event()


func _refresh() -> void:
	var v := current()
	text = ("%s   <  %s  >" % [label_text, v]) if label_text != "" else ("<  %s  >" % v)
