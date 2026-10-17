class_name CpuInput
extends InputSource
## Placeholder for the P1 vs CPU mode. A future AI reads the match state via
## the attached MatchDirector and emits InputFrames like a human would, so the
## fighter code needs no AI-specific branches.

var _director: Node
var _slot: int = -1


func attach(context: Node, slot: int) -> void:
	_director = context
	_slot = slot


func _sample(_tick: int) -> InputFrame:
	return InputFrame.new()  # TODO: AI. Idle for now.
