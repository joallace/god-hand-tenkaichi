class_name ReplayInput
extends InputSource
## Plays back recorded frames (Replay.inputs[slot]: InputFrame.WIRE_SIZE bytes
## per tick from tick 1). Pure function of the tick, so re-simulation and
## sources rebuilt mid-match (RECLAIM, load_state) read the same frames.
## Past the end: neutral frames.

var data: PackedByteArray


func _init(p_data: PackedByteArray = PackedByteArray()) -> void:
	data = p_data


func _sample(tick: int) -> InputFrame:
	return Replay.frame_from(data, tick)
