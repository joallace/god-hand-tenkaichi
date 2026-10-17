class_name ScriptedInput
extends InputSource
## Test input: returns pre-built frames indexed by (tick - start_tick).
## Builders take indices relative to start_tick; *_at_tick take absolute ticks.

var start_tick: int = 0
var frames: Array[InputFrame] = []


func _sample(tick: int) -> InputFrame:
	var i := tick - start_tick
	if i >= 0 and i < frames.size():
		return frames[i].duplicate_frame()
	return InputFrame.new()


func _ensure(n: int) -> void:
	while frames.size() < n:
		frames.append(InputFrame.new())


## Hold `btn` for `frames_held` frames starting at index `at` (press edge at `at`).
func press(at: int, btn: int, frames_held: int = 1) -> ScriptedInput:
	_ensure(at + frames_held)
	for i in range(at, at + frames_held):
		frames[i].held |= btn
	return self


func press_at_tick(tick: int, btn: int, frames_held: int = 1) -> ScriptedInput:
	return press(tick - start_tick, btn, frames_held)


func stick(from: int, to: int, v: Vector2) -> ScriptedInput:
	_ensure(to)
	for i in range(from, to):
		frames[i].set_move(v)
	return self


func flick(at: int, dir: InputFrame.Dodge) -> ScriptedInput:
	_ensure(at + 1)
	frames[at].dodge = dir
	return self


func snapshot() -> InputFrame:
	return _previous.duplicate_frame()


func restore(prev: InputFrame) -> void:
	_previous = prev.duplicate_frame()
