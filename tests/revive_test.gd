extends Node
## Headless tests for co-op downed / revive / out (SPEC §5.1): a `downable`
## fighter at 0 HP goes DOWNED (not KO), bleeds out to OUT, and a teammate
## holding TAUNT nearby revives it. Run as a scene:
##   godot --headless res://tests/revive_test.tscn

const B := InputFrame.Btn
const S := Fighter.State

var _failures := 0
var _events: Array = []  # [kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_downed_instead_of_ko, _test_bleed_out, _test_revive_completes,
		_test_cancel_on_release, _test_cancel_on_hit, _test_cancel_out_of_range,
		_test_one_reviver, _test_save_load_mid_revive, _test_revive_now,
		_test_versus_ko_unchanged,
	]
	for t in tests:
		t.call()
	print("REVIVE TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in FIGHT with one fighter per `teams` entry, ScriptedInput sources,
## team-0 fighters downable (co-op style) unless `downable` is false. Fighter
## i stands at positions[i] facing -Z.
func _new_match(teams: Array[int], positions: Array[Vector3], downable: bool = true) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	for i in teams.size():
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = teams[i]
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in teams.size():
		d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in teams.size():
		var f := d.fighters[i]
		f.downable = downable and f.team == 0
		f.reset_for_round(Transform3D(Basis.looking_at(Vector3.FORWARD), positions[i]))
		f.event.connect(func(kind: StringName, data: Dictionary) -> void: _events.append([kind, data]))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	for f in d.fighters:
		f.target = d.pick_default_target(f)
	return d


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _count(kind: StringName, slot: int = -1) -> int:
	var n := 0
	for e: Array in _events:
		if e[0] == kind and (slot < 0 or e[1]["slot"] == slot):
			n += 1
	return n


func _down(f: Fighter) -> void:
	f._set_health(0.0)
	f._enter_ko(Vector3.ZERO)


## P1 (slot 0) and P2 (slot 1, 1.5 m to the side) on team 0, an enemy far ahead.
func _coop_trio() -> MatchDirector:
	return _new_match([0, 0, 1], [Vector3.ZERO, Vector3(1.5, 0, 0), Vector3(0, 0, -12)])


# --- tests --------------------------------------------------------------------

func _test_downed_instead_of_ko() -> void:
	var d := _coop_trio()
	var f := d.fighters
	f[2].target = f[1]
	_down(f[1])
	_run(d, 2)
	_check(f[1].is_downed() and f[1].is_ko(), "downable fighter at 0 HP is DOWNED (and is_ko)")
	_check(_count(&"downed", 1) == 1 and _count(&"ko", 1) == 0, "emits downed, not ko")
	_check(f[1].get_hurtbox().is_empty() and not f[1].is_targetable(), "downed: no hurtbox, not targetable")
	_check(f[2].target == f[0], "the enemy re-targets away from the downed fighter")
	_check(f[1].bleed_out_ratio() > 0.0 and f[1].revive_progress() == 0.0, "bleed-out clock runs once landed")


func _test_bleed_out() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, Tuning.coop.bleed_out_frames + 2)
	_check(f[1].is_out() and f[1].is_ko(), "bleeds out to OUT")
	_check(_count(&"out", 1) == 1, "emits out once")
	_check(is_equal_approx(f[1].bleed_out_ratio(), 1.0) and f[1].get_hurtbox().is_empty(), "out: ratio 1, no hurtbox")
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, 20)
	_run(d, 10)
	_check(f[1].is_out() and f[0].current_state_name() == &"taunt", "TAUNT near an OUT teammate just taunts")


func _test_revive_completes() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, 2)
	var rf := Tuning.coop.revive_frames
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, rf + 10)
	_run(d, 2)
	_check(f[0].current_state_name() == &"revive" and f[1].reviving_slot() == 0, "TAUNT near a downed teammate starts a revive")
	_check(_count(&"revive_start", 1) == 1 and _count(&"taunt", 0) == 0, "revive_start, no taunt")
	var bleed := f[1].bleed_out_ratio()
	_run(d, rf / 2)
	_check(f[1].revive_progress() > 0.4 and f[1].revive_progress() < 0.6, "progress about halfway (%.2f)" % f[1].revive_progress())
	_check(is_equal_approx(f[1].bleed_out_ratio(), bleed), "bleed-out clock paused while being revived")
	_run(d, rf / 2 + 2)
	_check(not f[1].is_downed() and not f[1].is_ko(), "revived (state %s)" % f[1].current_state_name())
	_check(is_equal_approx(f[1].health, f[1].tuning.max_health * Tuning.coop.revive_health_ratio), "revived HP = revive_health_ratio")
	_check(f[1].ki == 0.0 and f[1].is_invulnerable(), "revived with 0 ki, wakeup invuln")
	_check(_count(&"revived", 1) == 1 and _count(&"revive_cancel") == 0, "revived event, no cancel")
	_check(f[0].current_state_name() != &"revive", "reviver back to neutral")


func _test_cancel_on_release() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, 2)
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, 30)
	_run(d, 40)
	_check(f[1].is_downed() and f[1].revive_progress() == 0.0, "releasing TAUNT cancels and resets progress")
	_check(_count(&"revive_cancel", 1) == 1 and f[0].current_state_name() != &"revive", "revive_cancel, reviver free")


func _test_cancel_on_hit() -> void:
	var d := _new_match([0, 0, 1], [Vector3.ZERO, Vector3(1.5, 0, 0), Vector3(0, 0, -1.2)])
	var f := d.fighters
	f[2].reset_for_round(Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0, -1.2)))  # facing P1
	_down(f[1])
	_run(d, 2)
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, 200)
	_run(d, 3)
	_check(f[0].current_state_name() == &"revive", "reviving with an enemy next to us")
	f[2].target = f[0]
	_src(d, 2).press(d.tick + 1 - _src(d, 2).start_tick, B.LIGHT)
	_run(d, 30)
	_check(_count(&"hit", 0) >= 1, "the reviver gets hit")
	_check(_count(&"revive_cancel", 1) == 1 and f[1].revive_progress() == 0.0 and f[1].is_downed(),
		"a hit on the reviver cancels the revive")


func _test_cancel_out_of_range() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, 2)
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, 200)
	_run(d, 10)
	f[0].global_position = Vector3(-Tuning.coop.revive_range * 3.0, 0, 0)
	_run(d, 2)
	_check(_count(&"revive_cancel", 1) == 1 and f[0].current_state_name() != &"revive", "moving out of range cancels")
	var far := _new_match([0, 0, 1], [Vector3.ZERO, Vector3(Tuning.coop.revive_range + 1.0, 0, 0), Vector3(0, 0, -12)])
	_down(far.fighters[1])
	_run(far, 2)
	_src(far, 0).press(far.tick + 1 - _src(far, 0).start_tick, B.TAUNT, 20)
	_run(far, 3)
	_check(far.fighters[0].current_state_name() == &"taunt", "out of range: TAUNT taunts")


func _test_one_reviver() -> void:
	var d := _new_match([0, 0, 0, 1], [Vector3.ZERO, Vector3(1.5, 0, 0), Vector3(1.5, 0, 1.5), Vector3(0, 0, -12)])
	var f := d.fighters
	_down(f[1])
	_run(d, 2)
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, 60)
	_run(d, 3)
	_src(d, 2).press(d.tick + 1 - _src(d, 2).start_tick, B.TAUNT, 60)
	_run(d, 3)
	_check(f[0].current_state_name() == &"revive" and f[1].reviving_slot() == 0, "first reviver owns the revive")
	_check(f[2].current_state_name() == &"taunt", "a second teammate just taunts")


func _snapshot(d: MatchDirector) -> String:
	return var_to_str(d.fighters.map(func(f: Fighter) -> Dictionary: return f.save_state()))


func _test_save_load_mid_revive() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, 2)
	_src(d, 0).press(d.tick + 1 - _src(d, 0).start_tick, B.TAUNT, Tuning.coop.revive_frames + 10)
	_run(d, 30)
	var saved := d.save_state()
	_run(d, 40)
	var a := _snapshot(d)
	d.load_state(saved)
	_check(f[1].reviving_slot() == 0 and f[0].current_state_name() == &"revive", "load restores the revive in progress")
	_run(d, 40)
	_check(_snapshot(d) == a, "re-simulating after load is identical")


func _test_revive_now() -> void:
	var d := _coop_trio()
	var f := d.fighters
	_down(f[1])
	_run(d, Tuning.coop.bleed_out_frames + 2)
	f[1].revive_now(0.5)
	_check(not f[1].is_ko() and f[1].current_state_name() == &"wakeup", "revive_now brings an OUT fighter back up")
	_check(is_equal_approx(f[1].health, f[1].tuning.max_health * 0.5), "revive_now uses the given ratio")
	_check(_count(&"revived", 1) == 1, "revived event (reviver -1)")
	f[0].revive_now(0.5)
	_check(f[0].health == f[0].tuning.max_health, "revive_now on a standing fighter does nothing")


func _test_versus_ko_unchanged() -> void:
	var d := _new_match([0, 1], [Vector3.ZERO, Vector3(0, 0, -4)], false)
	var f := d.fighters
	_down(f[0])
	_run(d, 2)
	_check(f[0].current_state_name() == &"ko" and _count(&"ko", 0) == 1 and _count(&"downed") == 0,
		"not downable: plain KO")
