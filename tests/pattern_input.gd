class_name PatternInput
extends InputSource
## Test input: a "player" repeating one attack pattern against its target,
## like a human looping jabs. Each cycle presses LIGHT `burst` times
## `link_frames` apart (string links), then waits `gap_frames` before the
## next cycle. Between cycles it walks in when out of `range_m`. It reads the
## match freely (it's a test driver, not a CPU), so it never needs
## save_state beyond the base edge tracking.

var director: MatchDirector
var slot: int = 0
var burst: int = 1
var link_frames: int = 8
var gap_frames: int = 20
var range_m: float = 1.3
## Cycle counter state.
var _next_press: int = 0
var _pressed_in_burst: int = 0
var _hold_frames: int = 0


func _init(p_burst: int = 1, p_gap: int = 20, p_link: int = 8) -> void:
	burst = p_burst
	gap_frames = p_gap
	link_frames = p_link


func attach(context: Node, p_slot: int) -> void:
	director = context as MatchDirector
	slot = p_slot


func _sample(tick: int) -> InputFrame:
	var f := InputFrame.new()
	var me := director.fighter_for_slot(slot) if director else null
	if me == null or me.target == null:
		return f
	var d := me.target.global_position - me.global_position
	d.y = 0.0
	if tick < _next_press:
		if _pressed_in_burst == 0 and d.length() > range_m:
			f.set_move(Vector2(0, 1))
		return f
	if _pressed_in_burst == 0 and d.length() > range_m:
		f.set_move(Vector2(0, 1))  # walk in, start the cycle once in range
		return f
	f.held |= InputFrame.Btn.LIGHT
	_pressed_in_burst += 1
	if _pressed_in_burst >= burst:
		_pressed_in_burst = 0
		_next_press = tick + gap_frames
	else:
		_next_press = tick + link_frames
	return f
