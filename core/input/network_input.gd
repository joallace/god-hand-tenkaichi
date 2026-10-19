class_name NetworkInput
extends InputSource
## History-backed input source for online play (SPEC_ONLINE.md §7.2).
##
## Online, EVERY human slot reads through one of these, local slots included:
## during a rollback resim a local slot must replay what was recorded for
## that tick, not poll the pad again. Local devices are sampled by the
## RollbackDriver and written into the shared InputHistory; remote frames
## arrive there through the Session. `_sample(tick)` is
## `history.frame_for(slot, tick)`: the confirmed frame, or a prediction
## (last confirmed frame with the dodge flick cleared), recorded as used so
## a later confirmation can detect the misprediction.
##
## Edge state (`_previous`) round-trips through save_state like every
## source; the history itself is the network log and is not saved.
##
## `NetworkInput.new()` (no args, as PlayerSlotConfig does) gets a private
## empty history and takes its slot from `attach()`; the driver can then
## point it at the session's history with `bind()`.

var history: InputHistory
var slot: int = -1


func _init(input_history: InputHistory = null, input_slot: int = -1) -> void:
	history = input_history if input_history else InputHistory.new()
	slot = input_slot


## Switch to `input_history` (and `input_slot` if >= 0).
func bind(input_history: InputHistory, input_slot: int = -1) -> void:
	history = input_history
	if input_slot >= 0:
		slot = input_slot


func attach(_context: Node, attach_slot: int) -> void:
	if slot < 0:
		slot = attach_slot


func _sample(tick: int) -> InputFrame:
	return history.frame_for(slot, tick)
