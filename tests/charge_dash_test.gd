extends Node
## Ki charge wind-up / release lag and forward dash startup / end lag /
## cooldown. Run as a scene:
##   godot --headless res://tests/charge_dash_test.tscn
## Prints PASS/FAIL per check and exits with 0 only if all pass.

const B := InputFrame.Btn

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_charge_windup, _test_charge_tap, _test_release_lag_blocks, _test_release_lag_guard,
		_test_release_lag_dodge, _test_windup_special, _test_hit_interrupts_charge,
		_test_dash_profile, _test_dash_attack_window, _test_dash_dodge, _test_dash_cooldown,
		_test_double_tap_dash,
		_test_round_trip_windup, _test_round_trip_cooldown,
	]
	for t in tests:
		t.call()
	print("CHARGE DASH TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Fresh match in the FIGHT phase, fighters `distance` apart on the Z axis.
func _new_match(distance: float) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in 2:
		d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in 2:
		var pos := Vector3(0, 0, distance * 0.5 if i == 0 else -distance * 0.5)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


## Runs `n` ticks; true if `f` was in `state_name` on every one of them.
func _stays(d: MatchDirector, f: Fighter, state_name: StringName, n: int) -> bool:
	for i in n:
		d.step()
		if f.current_state_name() != state_name:
			return false
	return true


# --- charge -------------------------------------------------------------------

func _test_charge_windup() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var before := p1.ki
	_src(d, 0).press(0, B.CHARGE, 120)
	_run(d, 1 + t.charge_windup_frames)  # entry tick + every wind-up frame
	_check(p1.current_state_name() == &"charge" and not p1.is_gaining_ki(), "charge wind-up: in charge, not gaining yet")
	_check(is_equal_approx(p1.ki, before), "no ki during the wind-up (%.2f -> %.2f)" % [before, p1.ki])
	_run(d, 1)
	_check(p1.is_gaining_ki() and p1.ki > before, "ki fills right after the wind-up (%.2f)" % p1.ki)
	_run(d, 60)
	_check(p1.ki > before + 60.0 * t.ki_charge_per_frame - 0.01, "ki keeps filling while held (%.1f)" % p1.ki)


func _test_charge_tap() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var before := p1.ki
	_src(d, 0).press(0, B.CHARGE, t.charge_windup_frames - 2)
	_run(d, t.charge_windup_frames)
	_check(p1.current_state_name() == &"charge_end", "releasing in the wind-up goes into the release lag")
	_check(is_equal_approx(p1.ki, before), "a CHARGE tap gains no ki")
	_check(p1.charge_lag_left() > 0 and not p1.can_dash(), "release lag pending, no dash meanwhile")
	_run(d, t.charge_release_lag_frames + 1)
	_check(p1.current_state_name() == &"idle" and p1.charge_lag_left() == 0, "release lag ends in idle")


func _test_release_lag_blocks() -> void:
	var d := _new_match(1.4)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var t := p1.tuning
	var hold := t.charge_windup_frames + 10
	var s := _src(d, 0)
	s.press(0, B.CHARGE, hold)
	# Stick + LIGHT + JUMP + DASH + CHARGE again right after letting go.
	s.stick(hold, hold + t.charge_release_lag_frames + 30, Vector2(0, 1))
	s.press(hold + 1, B.LIGHT).press(hold + 2, B.JUMP).press(hold + 3, B.DASH).press(hold + 4, B.CHARGE, 3)
	_run(d, hold + 1)
	_check(p1.current_state_name() == &"charge_end", "letting go of CHARGE enters the release lag")
	var pos := p1.global_position
	var stuck := _stays(d, p1, &"charge_end", t.charge_release_lag_frames - 2)
	_check(stuck, "release lag holds against walk / LIGHT / JUMP / DASH / CHARGE")
	_check(p1.global_position.distance_to(pos) < 0.01, "no walking during the release lag")
	_check(is_equal_approx(p2.health, p2.tuning.max_health), "no attack came out of the release lag")
	_run(d, 4)
	_check(p1.current_state_name() == &"walk", "walks once the lag is over (%s)" % p1.current_state_name())


func _test_release_lag_guard() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var hold := t.charge_windup_frames + 5
	var s := _src(d, 0)
	s.press(0, B.CHARGE, hold).press(hold + 1, B.GUARD, 3)
	s.stick(hold, hold + t.charge_release_lag_frames + 30, Vector2(0, 1))
	_run(d, hold + 2)
	_check(p1.current_state_name() == &"guard", "guard is allowed during the release lag")
	_run(d, 3)
	_check(p1.current_state_name() == &"charge_end", "a short guard doesn't skip the release lag")
	_run(d, t.charge_release_lag_frames)
	_check(p1.current_state_name() == &"walk", "walks after the remaining lag")


func _test_release_lag_dodge() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var hold := t.charge_windup_frames + 5
	_src(d, 0).press(0, B.CHARGE, hold).flick(hold + 2, InputFrame.Dodge.LEFT)
	_run(d, hold + 3)
	_check(p1.current_state_name() == &"dodge", "dodge is allowed during the release lag")


func _test_windup_special() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.CHARGE, 20).press(2, B.HEAVY)
	_run(d, 4)
	_check(p1.current_move() != null and p1.current_move().id == p1.def.super2,
		"CHARGE + HEAVY during the wind-up fires the special at once")


func _test_hit_interrupts_charge() -> void:
	var d := _new_match(1.4)
	var p1 := d.fighters[0]
	_src(d, 0).press(0, B.CHARGE, 60)
	_src(d, 1).press(2, B.LIGHT)
	var hit := false
	for i in 30:
		d.step()
		hit = hit or p1.current_state_name() == &"hitstun"
	_check(hit, "a hit interrupts the charge wind-up")


# --- dash ---------------------------------------------------------------------

func _test_dash_profile() -> void:
	var d := _new_match(20.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var total := t.dash_startup_frames + t.dash_frames + t.dash_end_lag_frames
	_src(d, 0).press(0, B.DASH)
	_run(d, 2)
	var z0 := p1.global_position.z
	_run(d, 1)
	var early := absf(p1.global_position.z - z0)
	_check(p1.dash_phase() == 0, "dash starts in its startup")
	_check(early < t.dash_speed / 60.0 * 0.5, "dash startup is slow (%.3f m/tick)" % early)
	_run(d, t.dash_startup_frames)
	z0 = p1.global_position.z
	_run(d, 1)
	_check(p1.dash_phase() == 1 and is_equal_approx(absf(p1.global_position.z - z0), t.dash_speed / 60.0),
		"full speed after the startup")
	_run(d, t.dash_frames)
	_check(p1.dash_phase() == 2 and p1.current_pose() == &"dash", "end lag after the travel")
	_run(d, total)
	_check(p1.current_state_name() == &"idle", "dash ends")
	var dist := absf(p1.global_position.z - 10.0)
	_check(absf(dist - p1.dash_distance(total)) < 0.3, "dash distance %.2f m ~ profile %.2f m" % [dist, p1.dash_distance(total)])
	_check(dist > 3.0 and dist < 4.5, "dash covers about the old distance (%.2f m)" % dist)


func _test_dash_attack_window() -> void:
	# LIGHT in the startup waits for the travel (buffer), never fires inside it.
	var d := _new_match(20.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	_src(d, 0).press(0, B.DASH).press(3, B.LIGHT)
	_check(_stays(d, p1, &"dash", t.dash_startup_frames + 1), "no dash attack during the startup")
	_run(d, 2)
	_check(p1.current_move() != null and p1.current_move().id == p1.def.dash_attack,
		"LIGHT buffered in the startup comes out as the dash attack")
	# LIGHT in the end lag: no dash attack.
	d = _new_match(20.0)
	p1 = d.fighters[0]
	var lag_at := t.dash_startup_frames + t.dash_frames + 2
	_src(d, 0).press(0, B.DASH).press(lag_at, B.LIGHT)
	var dash_attack := false
	for i in lag_at + t.dash_end_lag_frames:
		d.step()
		dash_attack = dash_attack or (p1.current_move() != null and p1.current_move().id == p1.def.dash_attack)
	_check(not dash_attack, "no dash attack in the end lag")


func _test_dash_dodge() -> void:
	var d := _new_match(20.0)
	var p1 := d.fighters[0]
	_src(d, 0).press(0, B.DASH).flick(2, InputFrame.Dodge.RIGHT)
	_run(d, 4)
	_check(p1.current_state_name() == &"dodge", "dodge cancels the dash startup")
	d = _new_match(20.0)
	p1 = d.fighters[0]
	var t := p1.tuning
	var lag_at := t.dash_startup_frames + t.dash_frames + 3
	_src(d, 0).press(0, B.DASH).flick(lag_at, InputFrame.Dodge.RIGHT)
	_run(d, lag_at + 2)
	_check(p1.current_state_name() == &"dodge", "dodge cancels the dash end lag")


func _test_dash_cooldown() -> void:
	var d := _new_match(30.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var total := t.dash_startup_frames + t.dash_frames + t.dash_end_lag_frames
	var s := _src(d, 0)
	s.press(0, B.DASH).press(total + 2, B.DASH)
	_run(d, total + 2)
	_check(p1.current_state_name() == &"idle" and not p1.can_dash(), "dash cooldown after a dash")
	_check(p1.dash_cooldown_left() > 0, "dash cooldown pending (%d)" % p1.dash_cooldown_left())
	_check(_stays(d, p1, &"idle", t.dash_cooldown_frames + 1), "a DASH press in the cooldown is dropped")
	_check(p1.can_dash(), "cooldown runs out")
	var at := d.tick + 1 - s.start_tick
	s.press(at, B.DASH)
	_run(d, 2)
	_check(p1.current_state_name() == &"dash", "dashes again after the cooldown")


## Ticks on which LocalDeviceInput's forward double tap fires for forward
## stick values `ys` (one per tick).
func _double_taps(ys: Array) -> Array[int]:
	var src := LocalDeviceInput.new(0, Bindings.Kind.KEYBOARD)
	var fired: Array[int] = []
	for tick in ys.size():
		var f := InputFrame.new()
		f.set_move(Vector2(0, ys[tick]))
		if src._forward_double_tap(f, tick, Tuning.input):
			fired.append(tick)
	return fired


func _test_double_tap_dash() -> void:
	var t: InputTuning = Tuning.input
	var gap := t.dash_tap_window_frames - 2
	var quick: Array = []
	quick.resize(gap)
	quick.fill(0.0)
	quick[0] = 1.0
	quick[1] = 1.0
	quick.append_array([1.0, 1.0, 1.0])
	_check(_double_taps(quick) == [gap], "forward tapped twice fires DASH once, on the second tap")
	var slow: Array = [1.0]
	slow.resize(t.dash_tap_window_frames + 2)
	slow.fill(0.0)
	slow[0] = 1.0
	slow.append(1.0)
	_check(_double_taps(slow).is_empty(), "taps further apart than the window don't dash")
	var held: Array = []
	held.resize(40)
	held.fill(1.0)
	_check(_double_taps(held).is_empty(), "holding forward doesn't dash")
	_check(_double_taps([1.0, 0.0, 1.0, 0.0, 1.0]) == [2], "a third tap starts a new pair")
	_check(Bindings.DEFAULT_PAD["DASH"].is_empty() and Bindings.DEFAULT_KEYBOARD[0]["DASH"].is_empty(),
		"DASH has no default button (double tap instead)")


# --- save / load -------------------------------------------------------------

func _round_trip(d: MatchDirector, ticks: int, label: String) -> void:
	var snap := d.save_state()
	var prev := [_src(d, 0).snapshot(), _src(d, 1).snapshot()]
	_run(d, ticks)
	var first := var_to_str(d.save_state())
	d.load_state(snap)
	_src(d, 0).restore(prev[0])
	_src(d, 1).restore(prev[1])
	_run(d, ticks)
	_check(first == var_to_str(d.save_state()), label)


func _test_round_trip_windup() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	_src(d, 0).press(0, B.CHARGE, t.charge_windup_frames + 8).stick(t.charge_windup_frames + 8, 60, Vector2(0, 1))
	_run(d, t.charge_windup_frames / 2)
	_check(p1.current_state_name() == &"charge" and not p1.is_gaining_ki(), "mid wind-up before the snapshot")
	_round_trip(d, 40, "save/load mid wind-up re-simulates identically")
	# Mid release lag: the lag counter must survive the load.
	d = _new_match(6.0)
	p1 = d.fighters[0]
	_src(d, 0).press(0, B.CHARGE, 4).stick(4, 60, Vector2(0, 1))
	_run(d, 7)
	_check(p1.current_state_name() == &"charge_end", "mid release lag before the snapshot")
	_round_trip(d, 30, "save/load mid release lag re-simulates identically")


func _test_round_trip_cooldown() -> void:
	var d := _new_match(30.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var total := t.dash_startup_frames + t.dash_frames + t.dash_end_lag_frames
	var s := _src(d, 0)
	s.press(0, B.DASH)
	for i in 6:
		s.press(total + 2 + i * 3, B.DASH)
	_run(d, total + 3)
	_check(p1.dash_cooldown_left() > 0, "mid cooldown before the snapshot")
	_round_trip(d, 60, "save/load mid dash cooldown re-simulates identically")
	d = _new_match(30.0)
	_src(d, 0).press(0, B.DASH)
	_run(d, 3)
	_round_trip(d, 40, "save/load mid dash startup re-simulates identically")
