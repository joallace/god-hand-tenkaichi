class_name NetworkInput
extends InputSource
## Placeholder for online play. Remote frames arrive tagged with their tick
## (`InputFrame.to_array()` over the wire). With input delay, `_sample` returns
## the frame for `tick`; with rollback it would return a prediction (repeat the
## last confirmed frame) and MatchDirector would re-simulate from a saved state
## once the real frame arrives (see SimEntity.save_state/load_state).

var _confirmed: Dictionary = {}  # tick -> InputFrame
var _last_confirmed: InputFrame = InputFrame.new()


func push_remote_frame(tick: int, data: PackedInt32Array) -> void:
	var f := InputFrame.from_array(data)
	_confirmed[tick] = f
	_last_confirmed = f


func _sample(tick: int) -> InputFrame:
	if _confirmed.has(tick):
		return (_confirmed[tick] as InputFrame).duplicate_frame()
	return _last_confirmed.duplicate_frame()  # prediction
