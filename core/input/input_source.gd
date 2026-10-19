class_name InputSource
extends RefCounted
## Abstract producer of InputFrames. One per player slot.
##
## Implementations: LocalDeviceInput (pad/keyboard), CpuInput (AI),
## NetworkInput (remote peer). MatchDirector calls `poll()` exactly once per
## simulation tick and hands the frame to the fighter.

var _previous: InputFrame = InputFrame.new()


## Called once per tick. Do not override; implement `_sample()` instead.
func poll(tick: int) -> InputFrame:
	var f := _sample(tick)
	f.compute_edges(_previous)
	_previous = f
	return f


## Override: return a frame with `move`, `held` and `dodge` filled in.
## Edge bits are computed by `poll()`.
func _sample(_tick: int) -> InputFrame:
	return InputFrame.new()


## Optional hook for sources that need match context (e.g. CPU needs to see
## the fighters). `context` is the MatchDirector.
func attach(_context: Node, _slot: int) -> void:
	pass


## Treat the device's current state as already-seen, so held buttons don't
## produce `pressed` edges on the next poll (used when resuming from pause).
func resync(tick: int) -> void:
	_previous = _sample(tick)


func reset() -> void:
	_previous = InputFrame.new()


## Rollback snapshot of the source's own state (edge tracking; subclasses
## with decision state, like CpuInput, extend it). PAUSE is left out: it is
## not sim input (the wire/replay format strips it), so a held pause button
## must not change the state hash.
func save_state() -> Dictionary:
	var prev := _previous.to_array()
	prev[2] &= ~InputFrame.Btn.PAUSE
	return {"previous": prev}


func load_state(s: Dictionary) -> void:
	_previous = InputFrame.from_array(s["previous"])
