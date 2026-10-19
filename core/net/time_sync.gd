class_name TimeSync
extends RefCounted
## GGPO-style frame advantage (SPEC_ONLINE.md §7.3). For each remote peer,
## the local advantage is `local_tick - (remote_tick + rtt_frames / 2)`: how
## many ticks this machine runs ahead of where that peer is right now.
## Samples are averaged over the last Tuning.net.timesync_window per peer.
## When the worst average exceeds Tuning.net.timesync_threshold, the
## RollbackDriver skips one frame, at most once every
## Tuning.net.timesync_interval frames; the slowest peer sets the pace.
##
## A wait shifts this machine one tick back relative to everyone, so every
## stored sample is lowered by one on a wait (otherwise old samples would
## keep asking for waits that already happened). The Session feeds samples
## from PING/PONG; call `clear()` at match start.

## peer -> Array[float] of recent advantage samples (oldest first)
var _samples: Dictionary = {}
var _last_wait_frame: int = -1


func clear() -> void:
	_samples.clear()
	_last_wait_frame = -1


func add_sample(peer: int, local_tick: int, remote_tick: int, rtt_frames: float) -> void:
	if not _samples.has(peer):
		_samples[peer] = [] as Array[float]
	var s: Array[float] = _samples[peer]
	s.append(local_tick - (remote_tick + rtt_frames * 0.5))
	while s.size() > Tuning.net.timesync_window:
		s.pop_front()


func remove_peer(peer: int) -> void:
	_samples.erase(peer)


## Averaged advantage over `peer` (0 with no samples).
func advantage(peer: int) -> float:
	if not _samples.has(peer):
		return 0.0
	var s: Array[float] = _samples[peer]
	if s.is_empty():
		return 0.0
	var total := 0.0
	for v in s:
		total += v
	return total / s.size()


## Largest averaged advantage over any peer (0 with no peers).
func max_advantage() -> float:
	var m := 0.0
	for peer: int in _samples:
		m = maxf(m, advantage(peer))
	return m


## Call once per frame with a frame counter; true = skip advancing the sim
## this frame.
func should_wait(frame: int) -> bool:
	if _last_wait_frame >= 0 and frame - _last_wait_frame < Tuning.net.timesync_interval:
		return false
	if max_advantage() <= Tuning.net.timesync_threshold:
		return false
	_last_wait_frame = frame
	for peer: int in _samples:
		var s: Array[float] = _samples[peer]
		for i in s.size():
			s[i] -= 1.0
	return true


## Input delay from the worst round trip the local inputs must make
## (SPEC_ONLINE.md §7.3): clamp(ceil(rtt/2 in frames) - rollback_comfort,
## input_delay_min, input_delay_max).
static func auto_input_delay(rtt_max_ms: float) -> int:
	var frame_ms := 1000.0 / Tuning.match_rules.tick_rate
	var one_way_frames := ceili(rtt_max_ms * 0.5 / frame_ms)
	return clampi(one_way_frames - Tuning.net.rollback_comfort,
		Tuning.net.input_delay_min, Tuning.net.input_delay_max)
