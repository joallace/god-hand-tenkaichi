class_name NumberStepper
extends Button
## Focusable "Label   <  1600  >" row for numbers, usable from a gamepad.
## ui_left / ui_right step by `step`; holding (key/stick repeat) switches to
## `step_fast` after Tuning.ui.stepper_fast_after_repeats repeats. With a
## keyboard, typing digits edits the number in place: Enter (or leaving the
## row) commits, Esc cancels, Backspace deletes. Values are clamped to
## [min_value, max_value]. `labels` maps values to display text (e.g. a
## port's default).

signal value_changed(value: int)

var label_text: String = ""
var min_value: int = 0
var max_value: int = 100
var step: int = 1
var step_fast: int = 10
## value -> display text instead of the number.
var labels: Dictionary = {}
var value: int = 0:
	set(v):
		value = v
		_refresh()

var _typing := ""
var _repeats := 0


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	alignment = HORIZONTAL_ALIGNMENT_CENTER
	focus_exited.connect(func() -> void:
		if is_typing():
			commit_typing())
	_refresh()


func setup(p_label: String, p_min: int, p_max: int, p_value: int, p_step := 1, p_fast := 10) -> NumberStepper:
	label_text = p_label
	min_value = p_min
	max_value = maxi(p_max, p_min)
	step = maxi(p_step, 1)
	step_fast = maxi(p_fast, step)
	value = clampi(p_value, min_value, max_value)
	return self


func is_typing() -> bool:
	return not _typing.is_empty()


## Change by `delta` (clamped); emits value_changed when it moved.
func nudge(delta: int) -> void:
	set_value_user(value + delta)


## Set from user input: clamp, refresh, emit if changed.
func set_value_user(v: int) -> void:
	if disabled:
		return
	var n := clampi(v, min_value, max_value)
	if n == value:
		_refresh()
		return
	value = n
	MenuHelpers.punch(self)
	Sfx.play(&"ui_move")
	value_changed.emit(value)


func commit_typing() -> void:
	var t := _typing
	_typing = ""
	if t.is_valid_int():
		set_value_user(t.to_int())
	else:
		_refresh()


func cancel_typing() -> void:
	_typing = ""
	_refresh()


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	var k := event as InputEventKey
	if k != null and k.pressed:
		var ch := char(k.unicode) if k.unicode > 0 else ""
		if ch.length() == 1 and ch >= "0" and ch <= "9":
			if _typing.length() < str(max_value).length():
				_typing += ch
			_refresh()
			accept_event()
			return
		if is_typing() and k.keycode == KEY_BACKSPACE:
			_typing = _typing.left(-1)
			_refresh()
			accept_event()
			return
	if is_typing():
		if event.is_action_pressed("ui_accept"):
			commit_typing()
			accept_event()
			return
		if event.is_action_pressed("ui_cancel"):
			cancel_typing()
			accept_event()
			return
	if event.is_action_pressed("ui_left", true) or event.is_action_pressed("ui_right", true):
		if is_typing():
			commit_typing()
		_repeats = _repeats + 1 if event.is_echo() else 0
		var s := step_fast if _repeats >= UiTheme.tuning().stepper_fast_after_repeats else step
		nudge(-s if event.is_action_pressed("ui_left", true) else s)
		accept_event()


func _refresh() -> void:
	var v: String
	if is_typing():
		v = _typing + "_"
	else:
		v = str(labels.get(value, value))
	text = ("%s   <  %s  >" % [label_text, v]) if label_text != "" else ("<  %s  >" % v)
