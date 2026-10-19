extends Node
## InputHistory (prediction, misprediction detection, contiguous confirmation,
## pruning), NetworkInput over it, and TimeSync.
## Run as a scene:  godot --headless res://tests/input_history_test.tscn

const B := InputFrame.Btn

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_prediction, _test_misprediction, _test_contiguous, _test_frames_since,
		_test_pruning, _test_normalization, _test_network_input, _test_time_sync,
		_test_auto_input_delay,
	]
	for t in tests:
		t.call()
	print("INPUT HISTORY TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _frame(mx: int, held: int = 0, dodge: InputFrame.Dodge = InputFrame.Dodge.NONE) -> InputFrame:
	var f := InputFrame.new()
	f.move_x = mx
	f.held = held
	f.dodge = dodge
	return f


func _test_prediction() -> void:
	var h := InputHistory.new()
	_check(h.frame_for(0, 1).equals(InputFrame.new()), "no input yet: predict neutral")
	h.add_confirmed(0, 1, _frame(50, B.GUARD, InputFrame.Dodge.LEFT))
	var c := h.frame_for(0, 1)
	_check(c.dodge == InputFrame.Dodge.LEFT and c.move_x == 50, "confirmed tick returns the confirmed frame (dodge kept)")
	var p := h.frame_for(0, 3)
	_check(p.move_x == 50 and p.held == B.GUARD, "prediction repeats the last confirmed frame")
	_check(p.dodge == InputFrame.Dodge.NONE, "prediction clears the dodge flick")
	_check(not h.is_confirmed(0, 3) and h.used_frame(0, 3).equals(p), "prediction recorded as used")
	p.move_x = 99
	_check(h.used_frame(0, 3).move_x == 50, "returned frame is a copy")
	# A later frame past a gap is used as the prediction base for ticks after it.
	h.add_confirmed(0, 5, _frame(-20))
	_check(h.frame_for(0, 6).move_x == -20 and h.frame_for(0, 4).move_x == 50,
		"prediction uses the last confirmed frame at or before the tick")


func _test_misprediction() -> void:
	var h := InputHistory.new()
	h.add_confirmed(0, 1, _frame(10))
	for t in range(2, 6):
		h.frame_for(0, t)  # sim predicts 10 for ticks 2..5
	_check(h.add_confirmed(0, 2, _frame(10)) == -1, "matching confirmation: no misprediction")
	_check(h.add_confirmed(0, 4, _frame(30)) == 4, "differing confirmation returns its tick")
	_check(h.add_confirmed(0, 3, _frame(10, 0, InputFrame.Dodge.BACK)) == 3, "a dodge the prediction missed is a misprediction")
	_check(h.add_confirmed(0, 3, _frame(77)) == -1, "re-confirming a tick is ignored")
	_check(h.confirmed_frame(0, 3).dodge == InputFrame.Dodge.BACK, "first confirmation wins")
	var h2 := InputHistory.new()
	for t in range(1, 8):
		h2.frame_for(1, t)
	var frames: Array = [_frame(0), _frame(0), _frame(5), _frame(0), _frame(6)]
	_check(h2.add_confirmed_frames(1, 1, frames) == 3, "batch add returns the earliest wrong tick")
	_check(h2.add_confirmed(1, 7, _frame(0)) == -1, "used frame equal to the confirmed one: no misprediction")
	_check(h2.add_confirmed(1, 50, _frame(9)) == -1, "tick never simulated: no misprediction")


func _test_contiguous() -> void:
	var h := InputHistory.new()
	_check(h.last_confirmed_tick(0) == 0, "nothing confirmed: first_tick - 1")
	h.add_confirmed(0, 1, _frame(1))
	h.add_confirmed(0, 3, _frame(3))
	_check(h.last_confirmed_tick(0) == 1 and h.latest_tick(0) == 3, "a gap stops the contiguous tick")
	h.add_confirmed(0, 2, _frame(2))
	_check(h.last_confirmed_tick(0) == 3, "filling the gap advances past buffered frames")
	h.add_confirmed(1, 1, _frame(1))
	_check(h.min_confirmed_tick([0, 1]) == 1, "min_confirmed_tick over slots")
	_check(h.min_confirmed_tick([0, 1, 2]) == 0, "a slot with nothing counts as first_tick - 1")
	_check(h.min_confirmed_tick([]) == InputHistory.NO_LIMIT, "no slots: NO_LIMIT")
	var h2 := InputHistory.new(10)
	h2.add_confirmed(0, 5, _frame(1))
	_check(h2.last_confirmed_tick(0) == 9 and not h2.is_confirmed(0, 5), "ticks before first_tick are ignored")


func _test_frames_since() -> void:
	var h := InputHistory.new()
	for t in range(1, 21):
		h.add_confirmed(0, t, _frame(t))
	var f := h.frames_since(0, 4, 5)
	_check(f.size() == 5 and f[0].move_x == 5 and f[4].move_x == 9, "frames_since: ack+1 onwards, capped")
	_check(h.frames_since(0, 18, 10).size() == 2, "frames_since stops at the contiguous tick")
	_check(h.frames_since(0, 20, 10).is_empty(), "nothing after the last confirmed tick")


func _test_pruning() -> void:
	var keep := Tuning.net.desync_dump_input_ticks
	var h := InputHistory.new()
	var n := keep + 50
	for t in range(1, n + 1):
		h.frame_for(0, t)
		h.add_confirmed(0, t, _frame(t % 100))
	h.prune(n)
	_check(not h.is_confirmed(0, n - keep - 1) and h.used_frame(0, n - keep - 1) == null,
		"prune drops ticks older than desync_dump_input_ticks")
	_check(h.is_confirmed(0, n - keep), "prune keeps the dump window")
	h.add_confirmed(0, 3, _frame(1))
	_check(not h.is_confirmed(0, 3), "pruned ticks are not re-added")
	h.prune(5)
	_check(h.is_confirmed(0, n - keep), "pruning never moves backwards")
	_check(h.last_confirmed_tick(0) == n, "pruning keeps the contiguous tick")


func _test_normalization() -> void:
	var h := InputHistory.new()
	var f := _frame(3, B.LIGHT | B.PAUSE)
	f.pressed = B.LIGHT
	h.add_confirmed(0, 1, f)
	var c := h.confirmed_frame(0, 1)
	_check(c.held == B.LIGHT and c.pressed == 0, "stored frames lose PAUSE and edge bits")
	var wire := InputFrame.decode_from(c.to_bytes(), 0)
	_check(wire.equals(c), "a stored frame equals its wire copy")


func _test_network_input() -> void:
	var h := InputHistory.new()
	var src := NetworkInput.new(h, 2)
	h.add_confirmed(2, 1, _frame(0, B.HEAVY))
	var f1 := src.poll(1)
	_check(f1.just_pressed(B.HEAVY), "NetworkInput derives edges from history frames")
	var f2 := src.poll(2)
	_check(f2.is_held(B.HEAVY) and not f2.just_pressed(B.HEAVY), "predicted frame holds without a new edge")
	_check(h.used_frame(2, 2) != null, "NetworkInput records the frame as used")
	var plain := NetworkInput.new()
	plain.attach(null, 3)
	_check(plain.slot == 3 and plain.poll(1).equals(InputFrame.new()), "no-arg NetworkInput works (private history)")
	plain.bind(h, 2)
	_check(plain.poll(1).is_held(B.HEAVY), "bind() switches to a shared history")
	var cfg := PlayerSlotConfig.new()
	cfg.input_kind = PlayerSlotConfig.InputKind.NETWORK
	_check(cfg.create_input_source() is NetworkInput, "PlayerSlotConfig still builds a NetworkInput")


func _test_time_sync() -> void:
	var ts := TimeSync.new()
	ts.add_sample(2, 100, 100, 0.0)
	_check(is_equal_approx(ts.advantage(2), 0.0), "in step: advantage 0")
	ts.clear()
	ts.add_sample(2, 110, 100, 6.0)
	_check(is_equal_approx(ts.advantage(2), 7.0), "advantage = local - (remote + rtt/2)")
	ts.clear()
	for i in Tuning.net.timesync_window * 2:
		ts.add_sample(2, 100 + i, 100 + i, 0.0)
	_check(not ts.should_wait(0), "no advantage: never waits")
	ts.clear()
	var ahead := ceili(Tuning.net.timesync_threshold + 2.0)
	for i in Tuning.net.timesync_window:
		ts.add_sample(3, 100 + i + ahead, 100 + i, 0.0)
	ts.add_sample(4, 50, 60, 0.0)
	_check(ts.max_advantage() > Tuning.net.timesync_threshold, "ahead of one peer counts even when behind another")
	_check(ts.should_wait(10), "ahead beyond threshold: wait")
	_check(not ts.should_wait(11), "at most one wait per interval")
	var waits := 1
	for f in range(12, 10 + Tuning.net.timesync_interval * 10):
		if ts.should_wait(f):
			waits += 1
	_check(waits == ahead - floori(Tuning.net.timesync_threshold),
		"waits stop once the advantage is spent (%d waits)" % waits)
	ts.remove_peer(3)
	_check(ts.max_advantage() <= 0.0, "remove_peer forgets its samples")
	ts.clear()
	for i in Tuning.net.timesync_window + 10:
		ts.add_sample(5, 0, 0, 0.0)
	ts.add_sample(5, Tuning.net.timesync_window, 0, 0.0)
	_check(is_equal_approx(ts.advantage(5), 1.0), "average over the last timesync_window samples")


func _test_auto_input_delay() -> void:
	var frame_ms := 1000.0 / Tuning.match_rules.tick_rate
	_check(TimeSync.auto_input_delay(0.0) == Tuning.net.input_delay_min, "LAN: minimum delay")
	_check(TimeSync.auto_input_delay(10000.0) == Tuning.net.input_delay_max, "huge ping: maximum delay")
	var rtt := 2.0 * frame_ms * (Tuning.net.rollback_comfort + 3) - 1.0
	var expected := clampi(3, Tuning.net.input_delay_min, Tuning.net.input_delay_max)
	_check(TimeSync.auto_input_delay(rtt) == expected, "ceil(rtt/2 in frames) - rollback_comfort")
