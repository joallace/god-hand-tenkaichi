class_name LocalDeviceInput
extends InputSource
## Reads one local device (a specific joypad by id, or the keyboard) using the
## rebindable profile of `slot` from the Bindings autoload.
##
## Gamepad: left stick / d-pad = move, right stick flick = dodge.
## Both: forward tapped twice = DASH (see InputTuning.dash_tap_*).
## Stick "up" maps to +Y = toward the opponent (cameras sit behind the fighter
## looking at the opponent, so screen-up and fighter-forward agree).

var slot: int
var kind: int  # Bindings.Kind
var device_id: int

const NO_TAP := -1 << 30

var _dodge_armed := true
var _prev_dodge_keys := 0
## Forward double tap: armed once forward was let go, tick of the first tap.
var _fwd_armed := true
var _fwd_tap_tick := NO_TAP


func _init(p_slot: int, p_kind: int, p_device_id: int = -1) -> void:
	slot = p_slot
	kind = p_kind
	device_id = p_device_id


func _sample(tick: int) -> InputFrame:
	var t: InputTuning = Tuning.input
	var f := InputFrame.new()

	for action in Bindings.BUTTON_ACTIONS:
		var b: Dictionary = Bindings.get_binding(slot, kind, action)
		if Bindings.is_binding_active(b, device_id, t.trigger_threshold):
			f.held |= InputFrame.Btn[action]

	if kind == Bindings.Kind.PAD:
		_sample_pad(f, t)
	else:
		_sample_keyboard(f, t)
	if _forward_double_tap(f, tick, t):
		f.held |= InputFrame.Btn.DASH
	return f


## True on the tick forward is pressed for the second time within
## dash_tap_window_frames (press to press); a pair consumes both taps.
func _forward_double_tap(f: InputFrame, tick: int, t: InputTuning) -> bool:
	var y := f.move().y
	if not _fwd_armed:
		_fwd_armed = y <= t.dash_tap_rearm
		return false
	if y < t.dash_tap_threshold:
		return false
	_fwd_armed = false
	if tick - _fwd_tap_tick <= t.dash_tap_window_frames:
		_fwd_tap_tick = NO_TAP
		return true
	_fwd_tap_tick = tick
	return false


func _sample_pad(f: InputFrame, t: InputTuning) -> void:
	var stick := Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X),
		-Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y))
	var dpad := Vector2(
		float(Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_RIGHT)) - float(Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_LEFT)),
		float(Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_UP)) - float(Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_DOWN)))
	if dpad != Vector2.ZERO:
		stick = dpad.normalized()
	f.set_move(_radial_deadzone(stick, t.stick_deadzone))

	# Right stick flick: fire once when crossing flick_threshold, re-arm once
	# the stick returns under flick_rearm.
	var rs := Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_RIGHT_X),
		-Input.get_joy_axis(device_id, JOY_AXIS_RIGHT_Y))
	var mag := rs.length()
	if _dodge_armed and mag >= t.flick_threshold:
		f.dodge = _dir_from_vector(rs)
		_dodge_armed = false
	elif mag <= t.flick_rearm:
		_dodge_armed = true


func _sample_keyboard(f: InputFrame, _t: InputTuning) -> void:
	var v := Vector2(
		float(_key("MOVE_RIGHT")) - float(_key("MOVE_LEFT")),
		float(_key("MOVE_FORWARD")) - float(_key("MOVE_BACK")))
	f.set_move(v.normalized())

	var dodge_keys := 0
	var dirs := [InputFrame.Dodge.FORWARD, InputFrame.Dodge.BACK, InputFrame.Dodge.LEFT, InputFrame.Dodge.RIGHT]
	var names := ["DODGE_FORWARD", "DODGE_BACK", "DODGE_LEFT", "DODGE_RIGHT"]
	for i in 4:
		if _key(names[i]):
			dodge_keys |= 1 << i
			if _prev_dodge_keys & (1 << i) == 0 and f.dodge == InputFrame.Dodge.NONE:
				f.dodge = dirs[i]
	_prev_dodge_keys = dodge_keys


func _key(action: String) -> bool:
	return Bindings.is_binding_active(Bindings.get_binding(slot, kind, action), -1, 0.5)


static func _radial_deadzone(v: Vector2, dz: float) -> Vector2:
	var m := v.length()
	if m < dz:
		return Vector2.ZERO
	return v / m * minf((m - dz) / (1.0 - dz), 1.0)


static func _dir_from_vector(v: Vector2) -> InputFrame.Dodge:
	if absf(v.x) > absf(v.y):
		return InputFrame.Dodge.RIGHT if v.x > 0 else InputFrame.Dodge.LEFT
	return InputFrame.Dodge.FORWARD if v.y > 0 else InputFrame.Dodge.BACK


func reset() -> void:
	super.reset()
	_dodge_armed = true
	_prev_dodge_keys = 0
	_fwd_armed = true
	_fwd_tap_tick = NO_TAP
