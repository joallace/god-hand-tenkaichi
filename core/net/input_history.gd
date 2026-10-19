class_name InputHistory
extends RefCounted
## The network input log (SPEC_ONLINE.md §7.1-7.2): per slot, the confirmed
## frame of every tick, and the frame the sim actually USED for each tick
## (a prediction, or the confirmed frame if it was known in time).
##
## - `add_confirmed()` stores a real frame (local or remote) and reports a
##   misprediction when the sim already used a different frame for that tick:
##   the RollbackDriver rolls back to the earliest such tick.
## - `frame_for()` is what NetworkInput hands the sim: the confirmed frame, or
##   a prediction = the last confirmed frame at or before the tick with
##   `dodge` cleared (a flick is an edge; repeating it would predict a second
##   dodge). Either way it is recorded as used.
## - Confirmation is tracked contiguously: `last_confirmed_tick(slot)` is the
##   highest tick T such that every tick first_tick..T is confirmed (frames
##   past a gap are kept and used, but don't advance it). Acks and the
##   rollback window use this.
##
## Frames are normalized on the way in (edge bits cleared, PAUSE stripped) so
## a local frame and its wire copy on another machine are identical.
## Not part of save_state: it is the log the sim is replayed from.

## Returned by min_confirmed_tick() for an empty slot list (nothing to wait on).
const NO_LIMIT := 0x7FFFFFFF

## First tick that carries input (MatchDirector's first step() is tick 1).
var first_tick: int = 1

## slot -> {tick: InputFrame}
var _confirmed: Dictionary = {}
## slot -> {tick: InputFrame}
var _used: Dictionary = {}
## slot -> contiguous last confirmed tick
var _contig: Dictionary = {}
## slot -> highest confirmed tick (may be past a gap)
var _latest: Dictionary = {}
## Ticks below this are ignored (before first_tick, or pruned).
var _pruned_before: int = 0


func _init(first: int = 1) -> void:
	reset(first)


func reset(first: int = 1) -> void:
	first_tick = first
	_pruned_before = first
	_confirmed.clear()
	_used.clear()
	_contig.clear()
	_latest.clear()


## Store the real frame of `slot` at `tick`. Returns `tick` if the sim had
## already used a different frame for it (misprediction), else -1. Repeats
## of an already-confirmed tick, and ticks before first_tick or already
## pruned, are ignored (-1).
func add_confirmed(slot: int, tick: int, frame: InputFrame) -> int:
	if tick < _pruned_before:
		return -1
	var conf := _slot_dict(_confirmed, slot)
	if conf.has(tick):
		return -1
	var f := _normalized(frame)
	conf[tick] = f
	if tick > int(_latest.get(slot, first_tick - 1)):
		_latest[slot] = tick
	var c: int = _contig.get(slot, first_tick - 1)
	while conf.has(c + 1):
		c += 1
	_contig[slot] = c
	var used: InputFrame = _slot_dict(_used, slot).get(tick)
	if used != null and not used.equals(f):
		return tick
	return -1


## add_confirmed for `frames` at ticks first..first+n-1. Returns the earliest
## mispredicted tick, or -1.
func add_confirmed_frames(slot: int, first: int, frames: Array) -> int:
	var earliest := -1
	for i in frames.size():
		var t := add_confirmed(slot, first + i, frames[i])
		if t >= 0 and (earliest < 0 or t < earliest):
			earliest = t
	return earliest


## The frame the sim should use for `slot` at `tick` (confirmed, else a
## prediction), recorded as used. Returns a fresh copy the caller may modify.
func frame_for(slot: int, tick: int) -> InputFrame:
	var f: InputFrame = _slot_dict(_confirmed, slot).get(tick)
	if f == null:
		f = _predict(slot, tick)
	_slot_dict(_used, slot)[tick] = f
	return f.duplicate_frame()


func is_confirmed(slot: int, tick: int) -> bool:
	return _slot_dict(_confirmed, slot).has(tick)


## Confirmed frame (do not modify) or null.
func confirmed_frame(slot: int, tick: int) -> InputFrame:
	return _slot_dict(_confirmed, slot).get(tick)


## Frame recorded by frame_for (do not modify) or null.
func used_frame(slot: int, tick: int) -> InputFrame:
	return _slot_dict(_used, slot).get(tick)


## Highest tick with every tick from first_tick confirmed (first_tick - 1
## when none).
func last_confirmed_tick(slot: int) -> int:
	return _contig.get(slot, first_tick - 1)


## Highest confirmed tick, gaps allowed.
func latest_tick(slot: int) -> int:
	return _latest.get(slot, first_tick - 1)


## Lowest last_confirmed_tick over `slots` (NO_LIMIT if `slots` is empty).
func min_confirmed_tick(slots: Array) -> int:
	var m := NO_LIMIT
	for s: int in slots:
		m = mini(m, last_confirmed_tick(s))
	return m


## Confirmed frames for ticks after `tick`, contiguous, at most `max_count`:
## ticks tick+1 .. min(last_confirmed_tick, tick+max_count). The redundancy
## payload for a destination that has acked `tick`. Do not modify them.
func frames_since(slot: int, tick: int, max_count: int) -> Array[InputFrame]:
	var out: Array[InputFrame] = []
	var conf := _slot_dict(_confirmed, slot)
	var last := mini(last_confirmed_tick(slot), tick + max_count)
	for t in range(maxi(tick + 1, _pruned_before), last + 1):
		out.append(conf[t])
	return out


## Slots that have any confirmed or used frame.
func slots() -> Array[int]:
	var out: Array[int] = []
	for s: int in _confirmed:
		out.append(s)
	for s: int in _used:
		if not out.has(s):
			out.append(s)
	out.sort()
	return out


## Forget ticks older than what a desync dump needs: everything below
## `confirmed_tick - Tuning.net.desync_dump_input_ticks`. Call with the
## session's confirmed tick (all slots confirmed up to it).
func prune(confirmed_tick: int) -> void:
	prune_before(confirmed_tick - Tuning.net.desync_dump_input_ticks)


## Forget every tick below `tick` (never moves backwards). Later adds and
## predictions ignore pruned ticks.
func prune_before(tick: int) -> void:
	if tick <= _pruned_before:
		return
	for dict: Dictionary in [_confirmed, _used]:
		for slot: int in dict:
			var d: Dictionary = dict[slot]
			for t: int in d.keys():
				if t < tick:
					d.erase(t)
	_pruned_before = tick


func _slot_dict(dict: Dictionary, slot: int) -> Dictionary:
	if not dict.has(slot):
		dict[slot] = {}
	return dict[slot]


func _predict(slot: int, tick: int) -> InputFrame:
	var conf := _slot_dict(_confirmed, slot)
	var t := mini(tick, latest_tick(slot))
	while t >= _pruned_before:
		var f: InputFrame = conf.get(t)
		if f != null:
			var p := f.duplicate_frame()
			p.dodge = InputFrame.Dodge.NONE
			return p
		t -= 1
	return InputFrame.new()


static func _normalized(frame: InputFrame) -> InputFrame:
	var f := frame.duplicate_frame()
	f.pressed = 0
	f.released = 0
	f.held &= ~InputFrame.Btn.PAUSE
	return f
