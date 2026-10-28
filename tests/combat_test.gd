extends Node
## Headless combat tests with scripted inputs. Run as a scene:
##   godot --headless res://tests/combat_test.tscn
## Prints PASS/FAIL per check and exits with 0 only if all pass.

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_light_hit, _test_light_string, _test_guard, _test_guard_crash, _test_guard_poses,
		_test_guard_pose_switch, _test_chip_cant_ko, _test_counter_guard, _test_throw, _test_throw_break,
		_test_back_throw, _test_taunt, _test_teleport_direction, _test_smash_directions,
		_test_dodge_invuln, _test_perfect_dodge, _test_charge, _test_teleport,
		_test_vanish_battle, _test_ki_blast, _test_beam, _test_rush, _test_ultimate,
		_test_not_enough_ki, _test_jump_attack, _test_air_ki_blast, _test_air_specials, _test_duck_kick,_test_strike_heights, _test_height_vs_duck,
		_test_charge_strike_release, _test_charge_strike_stun, _test_charge_strike_guard,
		_test_charge_punch, _test_heavy_at_range_blast, _test_charge_heavy_special,
		_test_guard_teleport, _test_guard_vanish_escape, _test_guard_vanish, _test_guard_vanish_mash,
		_test_guard_vanish_first_hit, _test_guard_vanish_window_hp, _test_attack_tracking,
		_test_combo_scaling, _test_anti_loop_repeat, _test_anti_loop_relaunch, _test_air_tech,
		_test_quick_rise, _test_wakeup_roll, _test_stay_down, _test_dodge_chain, _test_dodge_lengths, _test_dodge_queued_attack,
		_test_determinism, _test_determinism_bt3, _test_determinism_air,
	]
	for t in tests:
		t.call()
	print("COMBAT TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Fresh match in the FIGHT phase, fighters `distance` apart on the Z axis.
func _new_match(distance: float = 1.4) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
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
		d.fighters[i].event.connect(func(kind: StringName, data: Dictionary) -> void:
			_events.append([i, kind, data]))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _run_until(d: MatchDirector, cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		d.step()
	return cond.call()


func _event_count(kind: StringName, slot: int = -1) -> int:
	var n := 0
	for e: Array in _events:
		if e[1] == kind and (slot < 0 or e[0] == slot):
			n += 1
	return n


func _last_event(kind: StringName) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i][1] == kind:
			return _events[i][2]
	return {}


func _max_combo(d: MatchDirector, slot: int, ticks: int) -> int:
	var best := 0
	for i in ticks:
		d.step()
		best = maxi(best, d.fighters[slot].combo_hits)
	return best


# --- tests ----------------------------------------------------------------------

func _test_light_hit() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT)
	_run(d, 30)
	_check(p2.health < p2.tuning.max_health, "light attack hits (P2 health %.1f)" % p2.health)
	_check(_event_count(&"hit", 1) == 1 and not _last_event(&"hit")["blocked"], "hit event emitted by victim")


func _test_light_string() -> void:
	var d := _new_match()
	var s := _src(d, 0)
	for i in range(0, 60, 4):
		s.press(i, B.LIGHT)
	var best := _max_combo(d, 0, 90)
	_check(best >= 4, "4-hit light string combos (max combo %d)" % best)
	# Finisher: light, then heavy -> knockdown.
	d = _new_match()
	_src(d, 0).press(0, B.LIGHT).press(8, B.HEAVY)
	var down := _run_until(d, func() -> bool: return d.fighters[1].current_state_name() == &"knockdown", 60)
	_check(down, "light -> heavy finisher knocks down")
	var reset := _run_until(d, func() -> bool: return d.fighters[0].combo_hits == 0, 200)
	_check(reset, "combo resets after the victim recovers")


func _test_guard() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	_src(d, 1).press(0, B.GUARD, 60)
	_src(d, 0).press(3, B.LIGHT)
	_run(d, 30)
	var dmg := p2.tuning.max_health - p2.health
	_check(dmg > 0.0 and dmg < 30.0 * 0.5, "guard reduces damage to chip (%.2f)" % dmg)
	_check(not _last_event(&"hit").is_empty() and _last_event(&"hit")["blocked"], "blocked hit flagged")
	_check(_last_event(&"hit").get("guard_result", -1) == MoveData.GuardResult.PLAIN and is_equal_approx(p2.ki, p2.tuning.ki_start),
		"a light is a plain block: no ki cost (%.1f)" % p2.ki)


## Ki guard with too little ki crashes the guard; mashing shortens the crash.
func _test_guard_crash() -> void:
	var lengths: Array[int] = []
	for mash: bool in [false, true]:
		var d := _new_match()
		var p2 := d.fighters[1]
		p2.ki = 5.0
		# High guard vs the mid kick = ki guard.
		_src(d, 1).press(0, B.GUARD, 300).stick(0, 300, Vector2(0, 1))
		_src(d, 0).press(2, B.HEAVY)
		var crashed := _run_until(d, func() -> bool: return p2.current_state_name() == &"guard_break", 60)
		_check(crashed and p2.is_guard_crashed() and _event_count(&"guard_break", 1) == 1 and p2.ki == 0.0,
			"ki guard on an empty gauge crashes the guard (mash %s)" % mash)
		if mash:
			for i in range(d.tick - _src(d, 1).start_tick, 300, 3):
				_src(d, 1).press(i, B.HEAVY)
		var n := 0
		while p2.current_state_name() == &"guard_break" and n < 300:
			d.step()
			n += 1
		lengths.append(n)
		_check(p2.ki >= p2.tuning.guard_crash_ki_refill, "guard crash ends with a ki refill (%.1f)" % p2.ki)
	_check(lengths[0] >= lengths[1] + 10 and lengths[0] <= Tuning.fighter.guard_break_stun_frames + Tuning.fighter.hitstop_heavy,
		"mashing shortens the guard crash (%d -> %d frames)" % [lengths[0], lengths[1]])


## Guard result per pose: matched heavy = push-off (attacker recoils),
## neighbouring pose = ki guard, opposite extreme = unblockable.
func _test_guard_poses() -> void:
	var cases := [
		# [attacker stick y, guard stick y, expected GuardResult or -1 = clean hit, label]
		[-1.0, -1.0, MoveData.GuardResult.PUSH_OFF, "low kick vs low guard pushes off"],
		[1.0, -1.0, -1, "high kick goes through a low guard"],
		[-1.0, 1.0, -1, "low kick goes through a high guard"],
		[0.0, 1.0, MoveData.GuardResult.KI_GUARD, "mid kick vs high guard is a ki guard"],
		[0.0, 0.0, MoveData.GuardResult.PUSH_OFF, "mid kick vs mid guard pushes off"],
	]
	for c: Array in cases:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		_src(d, 1).press(0, B.GUARD, 80).stick(0, 80, Vector2(0, c[1]))
		_src(d, 0).stick(2, 3, Vector2(0, c[0])).press(2, B.HEAVY)
		_run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 60)
		var hit := _last_event(&"hit")
		var expect: int = c[2]
		if expect < 0:
			_check(not hit.is_empty() and not hit["blocked"], c[3])
			continue
		_check(not hit.is_empty() and hit["blocked"] and hit["guard_result"] == expect, c[3])
		if expect == MoveData.GuardResult.PUSH_OFF:
			_check(p1.current_state_name() == &"recoil" and _event_count(&"push_off", 1) == 1,
				"push-off makes the attacker recoil")
			_check(p2.ki > p2.tuning.ki_start, "push-off gives the defender ki")
		if expect == MoveData.GuardResult.KI_GUARD:
			var m := p1.def.move(p1.def.heavy)
			_check(is_equal_approx(p2.ki, p2.tuning.ki_start - m.guard_ki_cost), "ki guard drains ki (%.1f)" % p2.ki)


func _test_guard_pose_switch() -> void:
	var d := _new_match(4.0)
	var p2 := d.fighters[1]
	var sw := p2.tuning.guard_pose_switch_frames
	_src(d, 1).press(0, B.GUARD, 80).stick(20, 80, Vector2(0, -1))
	_run(d, 20 + sw - 2)
	_check(p2.guard_pose() == MoveData.Height.MID, "a held guard keeps its pose for a moment")
	_run(d, 3)
	_check(p2.guard_pose() == MoveData.Height.LOW and p2.current_pose() == &"guard_low",
		"then switches to the stick's pose")
	d = _new_match(4.0)
	p2 = d.fighters[1]
	_src(d, 1).stick(0, 20, Vector2(0, 1)).press(0, B.GUARD, 20)
	_run(d, 2)
	_check(p2.guard_pose() == MoveData.Height.HIGH, "entering the guard takes the held pose at once")


func _test_chip_cant_ko() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	p2.health = 1.0
	_src(d, 1).press(0, B.GUARD, 60)
	_src(d, 0).press(3, B.LIGHT)
	_run(d, 30)
	_check(is_equal_approx(p2.health, 1.0) and not p2.is_ko() and _event_count(&"ko") == 0, "chip damage can't KO")


## Counter stance catches a string's first hit only inside its opening frames.
func _test_counter_guard() -> void:
	var caught := 0
	var blocked_late := false
	for k in range(14, 40):
		var d := _new_match()
		var p1 := d.fighters[0]
		_src(d, 1).press(0, B.GUARD, 120).stick(k, k + 1, Vector2(0, 1)).press(k, B.LIGHT)
		_src(d, 0).press(30, B.LIGHT)
		_run(d, 70)
		if _event_count(&"counter_guard", 1) == 1:
			caught += 1
			_check(p1.health < p1.tuning.max_health and _event_count(&"hit", 1) == 0,
				"counter guard: no damage taken, the counter attack lands (k=%d)" % k)
		elif k == 14:
			blocked_late = _event_count(&"hit", 1) == 1 and _last_event(&"hit")["blocked"]
	_check(caught == Tuning.fighter.counter_guard_window_frames,
		"counter window is %d frames (caught %d)" % [Tuning.fighter.counter_guard_window_frames, caught])
	_check(blocked_late, "an early counter stance still blocks")


func _test_throw() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 1).press(0, B.GUARD, 120)
	_src(d, 0).press(10, B.THROW)
	var grabbed := _run_until(d, func() -> bool: return p2.current_state_name() == &"thrown", 30)
	_check(grabbed and p1.current_state_name() == &"throw" and _event_count(&"throw", 0) == 1, "throw grabs through guard")
	var down := _run_until(d, func() -> bool: return p2.current_state_name() == &"knockdown", 30)
	var dmg := p1.def.move(p1.def.throw).damage
	_check(down and is_equal_approx(p2.health, p2.tuning.max_health - dmg), "throw executes: damage + knockdown (hp %.1f)" % p2.health)
	# Airborne fighters can't be grabbed.
	d = _new_match()
	_src(d, 1).press(0, B.JUMP)
	_src(d, 0).press(6, B.THROW)
	_run(d, 30)
	_check(_event_count(&"throw") == 0, "throw whiffs on a jumping opponent")


func _test_throw_break() -> void:
	for mashed: bool in [false, true]:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		_src(d, 0).press(10, B.THROW)
		if mashed:
			_src(d, 1).press(2, B.GUARD)  # a recent press: the break press isn't clean
		_run_until(d, func() -> bool: return p2.current_state_name() == &"thrown", 30)
		_src(d, 1).press_at_tick(d.tick + 2, B.GUARD)
		_run(d, 6)
		if mashed:
			_check(_event_count(&"throw_break") == 0, "mashed GUARD doesn't break a throw")
		else:
			_check(_event_count(&"throw_break", 1) == 1 and p1.current_state_name() == &"recoil"
				and p2.current_state_name() == &"recoil", "clean GUARD press breaks the throw")
			_run(d, 30)
			_check(is_equal_approx(p2.health, p2.tuning.max_health), "broken throw deals no damage")


func _test_back_throw() -> void:
	for back: bool in [false, true]:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		_src(d, 0).stick(10, 11, Vector2(0, -1 if back else 0)).press(10, B.THROW)
		_run_until(d, func() -> bool: return p2.current_state_name() == &"knockdown", 60)
		_run(d, 20)
		var behind := p2.global_position.z > p1.global_position.z  # P1 started on +z facing -z
		_check(behind == back, "%s throw sends the victim %s" % ["back" if back else "forward", "behind" if back else "ahead"])


func _test_taunt() -> void:
	var d := _new_match(4.0)
	var p1 := d.fighters[0]
	_src(d, 0).press(0, B.TAUNT)
	_run(d, p1.tuning.taunt_frames + 5)
	_check(_event_count(&"taunt", 0) == 1 and _event_count(&"taunt_done", 0) == 1
		and is_equal_approx(p1.ki, p1.tuning.ki_start + p1.tuning.taunt_ki_gain), "finished taunt pays ki (%.1f)" % p1.ki)
	d = _new_match()
	p1 = d.fighters[0]
	_src(d, 0).press(0, B.TAUNT)
	_src(d, 1).press(2, B.LIGHT)
	_run(d, p1.tuning.taunt_frames + 5)
	var jab := p1.def.move(p1.def.light_string[0]).damage
	_check(_event_count(&"taunt_done") == 0 and is_equal_approx(p1.tuning.max_health - p1.health, jab * p1.tuning.taunt_counter_damage_mult),
		"a hit interrupts the taunt and counts extra (%.1f)" % (p1.tuning.max_health - p1.health))


## The stick picks the reappear point around the opponent (P1 starts on +z
## facing -z, so its right is +x).
func _test_teleport_direction() -> void:
	var cases := [
		[Vector2.ZERO, Vector3(0, 0, -1), "neutral reappears behind the victim"],
		[Vector2(-1, 0), Vector3(-1, 0, 0), "stick left reappears on the left flank"],
		[Vector2(1, 0), Vector3(1, 0, 0), "stick right reappears on the right flank"],
		[Vector2(0, -1), Vector3(0, 0, 1), "stick back reappears in front of the victim"],
	]
	for c: Array in cases:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		p1.ki = p1.ki_max()
		_src(d, 0).press(0, B.LIGHT).press(8, B.TELEPORT).stick(8, 30, c[0])
		_run_until(d, func() -> bool: return p1.current_state_name() == &"teleport", 30)
		_run_until(d, func() -> bool: return p1.current_state_name() != &"teleport", 30)
		var rel := p1.global_position - p2.global_position
		rel.y = 0.0
		_check(rel.normalized().dot(c[1]) > 0.8, "%s (rel %s)" % [c[2], rel])


## LIGHT charge released with the stick = directional smash.
func _test_smash_directions() -> void:
	var cases := [
		[Vector2.ZERO, &"brawler_charge_punch", &"neutral"],
		[Vector2(0, 1), &"brawler_smash_up", &"forward"],
		[Vector2(0, -1), &"brawler_smash_down", &"back"],
		[Vector2(-1, 0), &"brawler_smash_left", &"left"],
	]
	for c: Array in cases:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		_src(d, 0).press(0, B.LIGHT, 40).stick(0, 60, c[0])
		_run_until(d, func() -> bool: return _event_count(&"charge_release", 0) == 1, 80)
		_check(_move_id(p1) == c[1] and _last_event(&"charge_release")["dir"] == c[2],
			"release %s -> %s" % [c[2], _move_id(p1)])
		var top := 0.0
		var x_min := 0.0
		for i in 60:
			d.step()
			top = maxf(top, p2.global_position.y)
			x_min = minf(x_min, p2.global_position.x)
		match c[2]:
			&"forward":
				_check(top > 1.0 and _event_count(&"knockdown", 1) == 1, "forward smash launches (top %.2f)" % top)
			&"back":
				_check(_event_count(&"ground_bounce", 1) == 1 and top > 0.3, "back smash ground-bounces (top %.2f)" % top)
			&"left":
				_check(x_min < -1.0, "left smash knocks the victim to the left (x %.2f)" % x_min)


func _test_dodge_invuln() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	_src(d, 1).flick(0, InputFrame.Dodge.RIGHT)
	_src(d, 0).press(1, B.LIGHT)
	# Past the perfect window but inside the invulnerability window.
	_run(d, p2.tuning.perfect_dodge_frames + 1)
	_check(p2.current_state_name() == &"dodge" and p2.is_invulnerable(), "dodge grants invulnerability")
	# Direct check: an overlapping hitbox during invuln frames is ignored.
	var hb := Hitbox.new()
	hb.source = d.fighters[0]
	hb.attacker = d.fighters[0]
	hb.move = d.fighters[0].def.move(&"brawler_jab1")
	hb.hit_id = 999
	hb.a = p2.global_position + Vector3.UP
	hb.b = hb.a
	hb.radius = 0.5
	hb.origin = d.fighters[0].global_position
	_check(p2.receive_hit(hb) == CombatEntity.Contact.NONE, "invulnerable fighter ignores an overlapping hitbox")
	_run(d, 25)
	_check(is_equal_approx(p2.health, p2.tuning.max_health), "sway avoids the jab (health %.1f)" % p2.health)
	_check(_event_count(&"perfect_dodge") == 0, "late dodge is not perfect")


func _test_perfect_dodge() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var ki_before := p2.ki
	# Jab becomes active 5 frames after the press; duck 3 frames after the
	# press so the hit lands on dodge frame 2 (< perfect_dodge_frames).
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 1).flick(3, InputFrame.Dodge.FORWARD)
	_run(d, 8)
	_check(_event_count(&"perfect_dodge", 1) == 1, "perfect dodge fires")
	_check(is_equal_approx(p2.health, p2.tuning.max_health), "perfect dodge takes no damage")
	_check(p2.ki >= ki_before + p2.tuning.ki_gain_on_perfect_dodge - 0.01, "perfect dodge grants ki")
	_check(p1.current_state_name() == &"guard_break", "perfect duck staggers the attacker")
	# Counter: attack right away during the window for bonus damage.
	_src(d, 1).press_at_tick(d.tick + 1, B.LIGHT)
	_run(d, 20)
	var dmg := p1.tuning.max_health - p1.health
	_check(dmg >= 30.0 * p2.tuning.perfect_dodge_counter_damage_mult - 0.01, "counter attack deals bonus damage (%.1f)" % dmg)


func _test_charge() -> void:
	var d := _new_match(4.0)
	var p1 := d.fighters[0]
	var before := p1.ki
	_src(d, 0).press(0, B.CHARGE, 60)
	_run(d, 30)
	_check(p1.current_state_name() == &"charge", "holding CHARGE enters charge state")
	_run(d, 40)
	_check(p1.ki > before + 50.0, "charging increases ki (%.1f -> %.1f)" % [before, p1.ki])
	_check(p1.current_state_name() == &"charge_end", "releasing CHARGE enters the release lag")
	_run(d, p1.tuning.charge_release_lag_frames)
	_check(p1.current_state_name() == &"idle", "the release lag ends in idle")


func _test_teleport() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.LIGHT).press(8, B.TELEPORT)
	var started := _run_until(d, func() -> bool: return p1.current_state_name() == &"teleport", 30)
	_check(started and _event_count(&"teleport", 0) == 1, "teleport starts after a hit")
	_check(is_equal_approx(p1.ki, p1.ki_max() - p1.tuning.teleport_cost_bars * p1.tuning.ki_bar_size), "teleport costs ki (%.1f)" % p1.ki)
	var back := _run_until(d, func() -> bool: return p1.current_state_name() != &"teleport", 30)
	var behind := (p1.global_position - p2.global_position).dot(-p2.global_basis.z) < 0.0
	_check(back and behind, "attacker reappears behind the victim")
	_check(p2.current_state_name() == &"hitstun", "victim still in hitstun after teleport")
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	var best := _max_combo(d, 0, 20)
	_check(best >= 2, "follow-up links after teleport (combo %d)" % best)


func _test_vanish_battle() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p1.ki = p1.ki_max()
	p2.ki = p2.ki_max()
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 1).press(7, B.TELEPORT)
	var esc := _run_until(d, func() -> bool: return p2.current_state_name() == &"teleport", 30)
	_check(esc and _event_count(&"vanish", 1) == 1, "vanish escape from hitstun")
	_check(is_equal_approx(p2.ki, p2.ki_max() - p2.tuning.vanish_escape_cost_bars * p2.tuning.ki_bar_size), "vanish escape costs ki (%.1f)" % p2.ki)
	_check(p1.current_state_name() == &"vanish_wait" and p1.in_vanish_battle(), "attacker put in vanish response window")
	_check(p1.combo_hits == 0, "attacker combo reset by escape")
	_run_until(d, func() -> bool: return p2.current_state_name() != &"teleport", 30)
	var behind := (p2.global_position - p1.global_position).dot(-p1.global_basis.z) < 0.0
	_check(behind, "defender reappears behind the attacker")
	# Attacker answers within the window -> exchange 1.
	_src(d, 0).press_at_tick(d.tick + 3, B.TELEPORT)
	var ans := _run_until(d, func() -> bool: return p1.current_state_name() == &"teleport", 20)
	_check(ans and int(_last_event(&"vanish")["exchange"]) == 1, "attacker responds: exchange 1")
	var cost1 := VanishBattle.cost_for(p1.tuning, 1)
	_check(is_equal_approx(p1.ki, p1.ki_max() - cost1), "exchange 1 costs more (%.1f)" % p1.ki)
	_check(p2.current_state_name() == &"vanish_wait", "defender now must respond")
	# Defender doesn't respond -> battle ends, attacker wins.
	var ended := _run_until(d, func() -> bool: return _event_count(&"vanish_battle_end") > 0, 60)
	_check(ended and int(_last_event(&"vanish_battle_end")["winner_slot"]) == 0, "battle ends when nobody responds")
	_check(not p1.in_vanish_battle() and not p2.in_vanish_battle(), "battle state cleared")


func _test_ki_blast() -> void:
	var d := _new_match(5.0)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var ki0 := p1.ki
	_src(d, 0).press(0, B.BLAST)
	var spawned := _run_until(d, func() -> bool: return not d.entities.is_empty(), 20)
	_check(spawned and d.entities[0] is KiBlast, "ki blast spawns a projectile")
	_check(is_equal_approx(p1.ki, ki0 - p1.tuning.ki_blast_cost), "ki blast costs ki")
	_run(d, 30)
	_check(p2.health < p2.tuning.max_health, "ki blast deals damage (%.1f)" % p2.health)
	_check(d.entities.is_empty(), "ki blast is consumed on hit")
	# Guarded blast: chip only.
	d = _new_match(5.0)
	p2 = d.fighters[1]
	_src(d, 1).press(0, B.GUARD, 60)
	_src(d, 0).press(0, B.BLAST)
	_run(d, 40)
	var dmg := p2.tuning.max_health - p2.health
	_check(dmg > 0.0 and dmg < 10.0, "ki blast blockable with chip (%.2f)" % dmg)


func _test_beam() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p1.ki = p1.ki_max()
	_src(d, 0).stick(0, 2, Vector2(0, 1)).press(0, B.SPECIAL)
	_run(d, 2)
	_check(is_equal_approx(p1.ki, p1.ki_max() - p1.tuning.super2_cost_bars * p1.tuning.ki_bar_size), "beam costs 2 bars")
	_run(d, 30)
	_check(not d.entities.is_empty() and d.entities[0] is Beam, "beam entity spawned")
	_run(d, 60)
	var hits := _event_count(&"hit", 1)
	_check(p2.health < p2.tuning.max_health and hits >= 3, "beam deals multi-hit damage (%d hits, hp %.1f)" % [hits, p2.health])


func _test_rush() -> void:
	var d := _new_match(3.0)
	var p1 := d.fighters[0]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.SPECIAL)
	var best := _max_combo(d, 0, 120)
	_check(_last_event(&"super_start").get("kind") == &"rush", "neutral SPECIAL starts the rush super")
	_check(best >= 5, "rush plays its auto combo (combo %d)" % best)


func _test_ultimate() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p1.ki = p1.ki_max()
	_src(d, 0).stick(0, 1, Vector2(0, -1)).press(0, B.SPECIAL)
	_run(d, 2)
	_check(_event_count(&"ultimate_start", 0) == 1 and d.world_freeze > 0, "ultimate emits ultimate_start and freezes")
	_check(is_zero_approx(p1.ki), "ultimate consumes the full gauge")
	_run(d, 200)
	_check(p2.health < p2.tuning.max_health - 100.0, "ultimate beam deals big damage (hp %.1f)" % p2.health)


func _test_not_enough_ki() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	p1.ki = 0.0
	_src(d, 0).press(0, B.SPECIAL).press(3, B.BLAST)
	_run(d, 10)
	_check(_event_count(&"not_enough_ki", 0) == 2 and p1.current_state_name() == &"idle", "specials need ki")


func _test_heavy_at_range_blast() -> void:
	var d := _new_match(5.0)
	var p1 := d.fighters[0]
	_src(d, 0).press(0, B.HEAVY)
	var spawned := _run_until(d, func() -> bool: return not d.entities.is_empty(), 20)
	_check(spawned and d.entities[0] is KiBlast and p1.current_move().id == p1.def.ki_blast,
		"HEAVY at range throws a ki blast")
	d = _new_match()
	p1 = d.fighters[0]
	_src(d, 0).press(0, B.HEAVY)
	_run(d, 3)
	_check(d.entities.is_empty() and p1.current_move() != null and p1.current_move().id == p1.def.heavy,
		"HEAVY in close combat strikes")
	# No ki at range: falls back to the strike.
	d = _new_match(5.0)
	p1 = d.fighters[0]
	p1.ki = 0.0
	_src(d, 0).press(0, B.HEAVY)
	_run(d, 3)
	_check(d.entities.is_empty() and p1.current_move() != null and p1.current_move().id == p1.def.heavy,
		"HEAVY at range without ki strikes")


func _test_charge_heavy_special() -> void:
	var cases := [[Vector2.ZERO, &"rush"], [Vector2(0, 1), &"beam"], [Vector2(0, -1), &"ultimate"]]
	for c: Array in cases:
		var d := _new_match(6.0)
		var p1 := d.fighters[0]
		p1.ki = p1.ki_max()
		_src(d, 0).press(0, B.CHARGE, 20).stick(8, 12, c[0]).press(10, B.HEAVY)
		_run(d, 8)
		_check(p1.current_state_name() == &"charge", "holding CHARGE charges before HEAVY")
		_run(d, 6)
		_check(_last_event(&"super_start").get("kind") == c[1], "CHARGE + HEAVY %s -> %s" % [c[0], c[1]])
	# Pressed together from neutral.
	var d := _new_match(3.0)
	d.fighters[0].ki = d.fighters[0].ki_max()
	_src(d, 0).press(0, B.CHARGE, 5).press(0, B.HEAVY)
	_run(d, 3)
	_check(_last_event(&"super_start").get("kind") == &"rush", "CHARGE + HEAVY on the same frame")


func _test_guard_teleport() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.LIGHT).press(8, B.GUARD)
	var started := _run_until(d, func() -> bool: return p1.current_state_name() == &"teleport", 30)
	_check(started and _event_count(&"teleport", 0) == 1, "GUARD right after a hit teleports")
	# Without a recent hit GUARD just guards.
	d = _new_match(4.0)
	p1 = d.fighters[0]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.GUARD, 10)
	_run(d, 5)
	_check(p1.current_state_name() == &"guard" and _event_count(&"teleport") == 0, "GUARD in neutral guards")


func _test_guard_vanish_escape() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 1).press(7, B.GUARD)
	var esc := _run_until(d, func() -> bool: return p2.current_state_name() == &"teleport", 30)
	_check(esc and _event_count(&"vanish", 1) == 1, "GUARD in hitstun vanishes")


func _test_guard_vanish() -> void:
	var startup := 0
	for early: bool in [false, true]:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		p2.ki = p2.ki_max()
		startup = p1.def.move(p1.def.light_string[0]).startup
		var at := 0 if early else maxi(startup - 2, 0)
		if early:
			_src(d, 0).press(20, B.LIGHT)  # guard held long before the hit
		else:
			_src(d, 0).press(0, B.LIGHT)
		_src(d, 1).press(at, B.GUARD, 60)
		_run(d, 40)
		if early:
			_check(_event_count(&"vanish", 1) == 0 and _event_count(&"hit", 1) == 1 and _last_event(&"hit")["blocked"],
				"GUARD held early blocks normally")
		else:
			_check(_event_count(&"vanish", 1) == 1 and _event_count(&"hit", 1) == 0 and is_equal_approx(p2.health, p2.tuning.max_health),
				"GUARD just before a hit vanishes instead")
			_check(is_equal_approx(p2.ki, p2.ki_max() - p2.tuning.guard_vanish_cost_bars * p2.tuning.ki_bar_size),
				"guard vanish costs ki (%.1f)" % p2.ki)


func _test_jump_attack() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.JUMP).press(8, B.LIGHT)
	var air := _run_until(d, func() -> bool: return p1.is_airborne(), 5)
	_check(air, "jump leaves the ground")
	_run(d, 60)
	_check(p2.health < p2.tuning.max_health and p1.global_position.y == 0.0, "jumping attack hits and lands")
	# Close HEAVY in the air: the dive kick angles down and knocks down.
	d = _new_match()
	p1 = d.fighters[0]
	p2 = d.fighters[1]
	_src(d, 0).press(0, B.JUMP).press(8, B.HEAVY)
	_check(_run_until(d, func() -> bool: return _move_id(p1) == &"brawler_dive_kick", 12), "jump + HEAVY = dive kick")
	_check(_run_until(d, func() -> bool: return p2.current_state_name() == &"knockdown", 40), "dive kick knocks down")
	_run(d, 30)
	_check(p1.global_position.y == 0.0 and p1.current_move() == null, "dive kick ends on landing")
	# One air action per jump.
	d = _new_match()
	p1 = d.fighters[0]
	_src(d, 0).press(0, B.JUMP).press(4, B.LIGHT).press(22, B.LIGHT)
	var starts := 0
	for i in 50:
		d.step()
		if p1.current_move() != null and p1.state_frame() == 0:
			starts += 1
	_check(starts == 1, "only one attack per jump (%d)" % starts)


func _test_air_ki_blast() -> void:
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.JUMP).press(8, B.HEAVY)
	_check(_run_until(d, func() -> bool: return _move_id(p1) == &"brawler_ki_blast", 12), "jump + HEAVY at range = ki blast")
	var y0 := p1.global_position.y
	_run(d, p1.current_move().air_hang_frames - 2)
	_check(y0 > 0.0 and is_equal_approx(p1.global_position.y, y0), "air ki blast stalls in the air (y %.2f -> %.2f)" % [y0, p1.global_position.y])
	_check(_event_count(&"ki_blast", 0) == 1, "air ki blast fires")
	_check(_run_until(d, func() -> bool: return p2.health < p2.tuning.max_health, 40), "air ki blast angles down and hits")
	_check(_run_until(d, func() -> bool: return p1.global_position.y == 0.0, 40), "falls after the stall")


func _test_air_specials() -> void:
	# Beam: hangs in the air and fires down at the opponent.
	var d := _new_match(6.0)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.JUMP).press(6, B.CHARGE, 4).stick(6, 10, Vector2(0, 1)).press(8, B.HEAVY)
	_check(_run_until(d, func() -> bool: return _move_id(p1) == &"brawler_beam", 12), "jump + CHARGE + fwd HEAVY = air beam")
	var y0 := p1.global_position.y
	_check(_run_until(d, func() -> bool: return not d.entities.is_empty(), 30), "air beam fires")
	var beam := d.entities[0] as Beam
	_check(beam != null and beam._dir.y < 0.0, "air beam aims down (dir %s)" % [beam._dir if beam else Vector3.ZERO])
	_run(d, 40)
	_check(is_equal_approx(p1.global_position.y, y0) and y0 > 0.0, "caster hangs while beaming (y %.2f)" % p1.global_position.y)
	_check(_event_count(&"hit", 1) >= 3, "air beam hits the grounded opponent (%d hits)" % _event_count(&"hit", 1))
	_check(_run_until(d, func() -> bool: return p1.global_position.y == 0.0 and p1.current_move() == null, 200),
		"lands after the air beam")
	# Rush: SPECIAL in the air dives in and plays its auto combo.
	d = _new_match(3.0)
	p1 = d.fighters[0]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.JUMP).press(8, B.SPECIAL)
	var best := _max_combo(d, 0, 140)
	_check(_last_event(&"super_start").get("kind") == &"rush", "SPECIAL in the air starts the rush")
	_check(best >= 5, "air rush dives in and combos (combo %d)" % best)


func _test_duck_kick() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var t := p1.tuning
	_src(d, 0).flick(0, InputFrame.Dodge.FORWARD).press(2, B.HEAVY)
	var frame := -1
	for i in 30:
		var was := p1.state_frame() if p1.current_state_name() == &"dodge" else -1
		d.step()
		if p1.current_state_name() == &"attack":
			frame = was + 1
			break
	_check(_move_id(p1) == &"brawler_duck_kick", "HEAVY during a duck = duck kick (got %s)" % _move_id(p1))
	_check(frame == t.duck_heavy_from_frame, "duck kick fires on frame %d (got %d)" % [t.duck_heavy_from_frame, frame])
	var hb := p1.get_hurtbox()
	_check((hb[1] as Vector3).y + float(hb[2]) <= t.duck_height + 0.001, "duck kick keeps a ducking hurtbox")
	_check(_run_until(d, func() -> bool: return p2.current_state_name() == &"knockdown", 30), "duck kick trips")
	# LIGHT in a duck and HEAVY in a sway keep their usual moves.
	d = _new_match()
	_src(d, 0).flick(0, InputFrame.Dodge.LEFT).press(2, B.HEAVY)
	_check(_run_until(d, func() -> bool: return _move_id(d.fighters[0]) == &"brawler_kick_mid", 30), "HEAVY in a sway = normal heavy")
	# A high kick active during the duck kick whiffs over it (control: the
	# same kick hits a standing fighter). Out of the duck kick's reach.
	for ducking: bool in [false, true]:
		d = _new_match(2.2)
		p1 = d.fighters[0]
		var p2k := d.fighters[1]
		_src(d, 1).stick(8, 9, Vector2(0, 1)).press(8, B.HEAVY)
		if ducking:
			_src(d, 0).flick(0, InputFrame.Dodge.FORWARD).press(1, B.HEAVY)
		var in_kick_when_active := true
		for i in 50:
			d.step()
			if ducking and p2k.attack_phase() == 1 and _move_id(p1) != &"brawler_duck_kick":
				in_kick_when_active = false
		var hit := p1.health < p1.tuning.max_health
		if ducking:
			_check(in_kick_when_active and not hit, "high kick whiffs over the duck kick (hp %.1f)" % p1.health)
		else:
			_check(hit, "control: the high kick reaches a standing fighter (hp %.1f)" % p1.health)


func _move_id(f: Fighter) -> StringName:
	return f.current_move().id if f.current_move() else &""


func _test_strike_heights() -> void:
	var cases := [[Vector2.ZERO, &"brawler_kick_mid"], [Vector2(0, 1), &"brawler_kick_high"],
		[Vector2(0, -1), &"brawler_kick_low"]]
	for c: Array in cases:
		var d := _new_match()
		_src(d, 0).stick(0, 1, c[0]).press(0, B.HEAVY)
		_run(d, 2)
		_check(_move_id(d.fighters[0]) == c[1], "stick %s + HEAVY -> %s (got %s)" % [c[0], c[1], _move_id(d.fighters[0])])
	# In the light string, the HEAVY finisher follows the stick too.
	var d := _new_match()
	_src(d, 0).press(0, B.LIGHT).stick(8, 9, Vector2(0, -1)).press(8, B.HEAVY)
	var low := _run_until(d, func() -> bool: return _move_id(d.fighters[0]) == &"brawler_finisher_low", 30)
	_check(low, "light -> back + HEAVY = low finisher")
	var down := _run_until(d, func() -> bool: return d.fighters[1].current_state_name() == &"knockdown", 40)
	_check(down, "low finisher trips")
	d = _new_match()
	_src(d, 0).press(0, B.LIGHT).stick(8, 9, Vector2(0, 1)).press(8, B.HEAVY)
	_check(_run_until(d, func() -> bool: return _move_id(d.fighters[0]) == &"brawler_finisher_high", 30),
		"light -> forward + HEAVY = high finisher")
	var launched := _run_until(d, func() -> bool: return d.fighters[1].global_position.y > 1.0, 60)
	_check(launched, "high finisher launches")


## A late duck (past its invulnerability) shrinks the hurtbox: high kicks
## sail over it, low kicks still connect.
func _test_height_vs_duck() -> void:
	for low: bool in [false, true]:
		var d := _new_match()
		var p2 := d.fighters[1]
		_src(d, 1).flick(0, InputFrame.Dodge.FORWARD)
		_src(d, 0).stick(1, 2, Vector2(0, -1 if low else 1)).press(1, B.HEAVY)
		_run(d, 30)
		if low:
			_check(p2.health < p2.tuning.max_health, "low kick hits a ducking opponent (hp %.1f)" % p2.health)
		else:
			_check(is_equal_approx(p2.health, p2.tuning.max_health), "high kick whiffs over a duck (hp %.1f)" % p2.health)


func _test_charge_strike_release() -> void:
	# A tap never charges.
	var d := _new_match()
	_src(d, 0).press(0, B.HEAVY)
	_run(d, 40)
	_check(_event_count(&"charge_start") == 0, "tapped HEAVY doesn't charge")
	# Hold briefly, release before the charge point: fires at once, no stun.
	d = _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.HEAVY, p1.tuning.charge_hold_frames + 4)
	var started := _run_until(d, func() -> bool: return _event_count(&"charge_start", 0) == 1, 20)
	_check(started and _move_id(p1) == &"brawler_charge_kick", "holding HEAVY starts the charge kick")
	_check(int(_last_event(&"charge_start")["button"]) == B.HEAVY, "charge_start reports the button")
	var released := _run_until(d, func() -> bool: return _event_count(&"charge_release", 0) == 1, 30)
	_check(released and is_zero_approx(_last_event(&"charge_release")["ratio"]), "early release fires uncharged")
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 30)
	_check(p2.current_state_name() == &"hitstun" and _event_count(&"stagger", 1) == 0, "weak charge strike: normal hitstun")
	var dmg := p2.tuning.max_health - p2.health
	var base := p1.def.move(&"brawler_charge_kick").damage
	_check(is_equal_approx(dmg, base), "uncharged damage is the base (%.1f)" % dmg)


func _test_charge_strike_stun() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var m := p1.def.move(&"brawler_charge_kick")
	# Charging starts at hold_frames, reaches charge_frame, then accumulates;
	# release at ~80% charge.
	var hold := p1.tuning.charge_hold_frames + m.charge_frame + roundi(m.charge_max_frames * 0.8)
	_src(d, 0).press(0, B.HEAVY, hold)
	_run(d, p1.tuning.charge_hold_frames + m.charge_frame + 10)
	_check(p1.is_charging_strike() and p1.charge_ratio() > 0.0, "charge kick holds while charging (%.2f)" % p1.charge_ratio())
	var hit := _run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 120)
	var ratio: float = _last_event(&"charge_release").get("ratio", 0.0)
	_check(hit and ratio > p1.tuning.charge_stun_ratio and ratio < 1.0, "released partially charged (%.2f)" % ratio)
	_check(p2.current_state_name() == &"guard_break" and _event_count(&"stagger", 1) == 1, "charged hit stuns the victim")
	var dmg := p2.tuning.max_health - p2.health
	_check(dmg > m.damage * 1.5, "charged damage scales up (%.1f)" % dmg)
	# Stunned long enough to follow up once the kick recovers.
	_run_until(d, func() -> bool: return p1.current_state_name() == &"idle", 60)
	_check(p2.current_state_name() == &"guard_break", "victim still stunned after the kick recovers")
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	var best := _max_combo(d, 0, 20)
	_check(best >= 2, "follow-up combos off the stun (combo %d)" % best)


func _test_charge_strike_guard() -> void:
	for full: bool in [false, true]:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		var m := p1.def.move(&"brawler_charge_kick")
		var hold := p1.tuning.charge_hold_frames + m.charge_frame + (m.charge_max_frames * 2 if full else m.charge_max_frames / 2)
		_src(d, 1).press(0, B.GUARD, 300)
		_src(d, 0).press(0, B.HEAVY, hold)
		_run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 200)
		var ratio: float = _last_event(&"charge_release").get("ratio", 0.0)
		if full:
			_check(is_equal_approx(ratio, 1.0), "holding auto-releases at full charge")
			_check(_event_count(&"guard_break", 1) == 1 and p2.is_guard_crashed(),
				"full charge crashes a guard with ki to spare")
		else:
			_check(_event_count(&"guard_break", 1) == 0 and p2.current_state_name() == &"guard_stun",
				"half charge is blocked (ki %.1f)" % p2.ki)
			_check(p2.ki < p2.tuning.ki_start - m.guard_ki_cost, "charge scales the ki guard cost")


func _test_charge_punch() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT, 40)
	var started := _run_until(d, func() -> bool: return _event_count(&"charge_start", 0) == 1, 30)
	_check(started and _move_id(p1) == &"brawler_charge_punch", "holding LIGHT: jab then charge punch")
	_check(_event_count(&"hit", 1) == 1, "the jab still landed first")
	_run(d, 90)
	_check(_event_count(&"hit", 1) >= 2, "charge punch connects (%d hits)" % _event_count(&"hit", 1))
	_check(p2.health < p2.tuning.max_health - 30.0 - p1.def.move(&"brawler_charge_punch").damage * 0.5,
		"charge punch damage (hp %.1f)" % p2.health)


## A GUARD press soon after the previous one blocks instead of vanishing.
func _test_guard_vanish_mash() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	var startup := p1.def.move(p1.def.light_string[0]).startup
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 1).press(0, B.GUARD).press(maxi(startup - 2, 2), B.GUARD, 60)
	_run(d, 40)
	_check(_event_count(&"vanish", 1) == 0 and _event_count(&"hit", 1) == 1 and _last_event(&"hit")["blocked"],
		"mashed GUARD blocks instead of vanishing")


## Only the first hit of a string can be guard-vanished.
func _test_guard_vanish_first_hit() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	_src(d, 1).press(0, B.GUARD, 200)
	_run(d, 70)
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	var blocked := _run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	# Clean re-press (the last one was long ago) right before the cancelled jab2.
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	var jab2 := p1.def.light_string[1]
	_run_until(d, func() -> bool: return _move_id(p1) == jab2, 30)
	var s1 := _src(d, 1)
	s1.frames.resize(d.tick - s1.start_tick + 1)
	s1.press_at_tick(d.tick + 2, B.GUARD, 40)
	_run(d, 30)
	_check(blocked and _event_count(&"hit", 1) == 2 and _last_event(&"hit")["blocked"] and _event_count(&"vanish", 1) == 0,
		"string follow-ups can't be guard-vanished")
	_check(p1.def.light_string.size() > 1, "light string has a follow-up")


func _test_guard_vanish_window_hp() -> void:
	var p := _new_match().fighters[1]
	var t := p.tuning
	_check(p.guard_vanish_window() == t.guard_vanish_window, "full-health guard vanish window")
	p.health = t.max_health * (t.guard_vanish_hurt_ratio - 0.01)
	_check(p.guard_vanish_window() == t.guard_vanish_window_hurt, "hurt guard vanish window")
	p.health = t.max_health * (t.guard_vanish_critical_ratio - 0.01)
	_check(p.guard_vanish_window() == t.guard_vanish_window_critical, "critical guard vanish window")


## Attacks turn slowly during startup and lock before active: an early
## sidestep makes them whiff.
func _test_attack_tracking() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT)
	_run(d, 1)
	var fwd0 := -p1.global_basis.z
	p2.global_position = p1.global_position + (p2.global_position - p1.global_position).rotated(Vector3.UP, deg_to_rad(70.0))
	var m := p1.def.move(p1.def.light_string[0])
	_run(d, m.startup)
	var turned := rad_to_deg(fwd0.angle_to(-p1.global_basis.z))
	_run(d, 30)
	var limit := p1.tuning.attack_track_turn_deg / 60.0 * (m.startup - p1.tuning.attack_track_lock_frames)
	_check(turned > 1.0 and turned <= limit + 0.5, "attack tracks slowly during startup (%.1f deg <= %.1f)" % [turned, limit])
	_check(_event_count(&"hit", 1) == 0, "sidestepped jab whiffs")


## First N hits full damage, then -step per hit.
func _test_combo_scaling() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var t := p1.tuning
	var ids: Array[StringName] = []
	for i in t.combo_scaling_start_hit + 1:
		var btn := B.LIGHT if i < t.combo_scaling_start_hit else B.HEAVY
		_src(d, 0).press_at_tick(d.tick + 1, btn)
		var n := i + 1
		_run_until(d, func() -> bool: return _event_count(&"hit", 1) == n, 40)
		ids.append(_move_id(p1))
	var hits: Array = []
	for e: Array in _events:
		if e[0] == 1 and e[1] == &"hit":
			hits.append(e[2]["damage"])
	var ok := hits.size() == ids.size()
	for i in mini(hits.size(), ids.size()):
		var scale := 1.0 if i < t.combo_scaling_start_hit else 1.0 - t.combo_scaling_step
		ok = ok and is_equal_approx(hits[i], p1.def.move(ids[i]).damage * scale)
	_check(ok, "first %d hits unscaled, then -%d%% (%s %s)" % [t.combo_scaling_start_hit, roundi(t.combo_scaling_step * 100), ids, hits])


## The same move landing twice in one combo pushes the victim out.
func _test_anti_loop_repeat() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	_run_until(d, func() -> bool: return p1.current_state_name() == &"idle", 40)
	p2._state_len = 500  # keep the victim reeling
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 2, 30)
	_check(p2.current_state_name() == &"knockdown" and _event_count(&"knockdown", 1) == 1,
		"repeated move in a combo pushes out into a knockdown")
	# A teleport starts a fresh segment: the same string may follow.
	d = _new_match()
	p1 = d.fighters[0]
	p2 = d.fighters[1]
	p1.ki = p1.ki_max()
	_src(d, 0).press(0, B.LIGHT).press(8, B.TELEPORT)
	_run_until(d, func() -> bool: return p1.current_state_name() == &"teleport", 30)
	_run_until(d, func() -> bool: return p1.current_state_name() != &"teleport", 30)
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 2, 30)
	_check(p2.current_state_name() == &"hitstun", "same move after a teleport still combos")


## Relaunching an airborne victim past the cap pushes out instead.
func _test_anti_loop_relaunch() -> void:
	for capped: bool in [false, true]:
		var d := _new_match()
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		p2._enter(Fighter.State.KNOCKDOWN)
		p2._land_frame = -1
		p2.global_position.y = 1.0
		p2._vel = Vector3(0, 3.0, 0)
		p2._combo_relaunches = p2.tuning.juggle_max_relaunches if capped else 0
		_src(d, 0).press(0, B.LIGHT)
		var hit := _run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
		var speed := Vector2(p2._vel.x, p2._vel.z).length()
		if capped:
			_check(hit and is_equal_approx(speed, p2.tuning.loop_pushout_speed) and p2._vel.y <= 0.0,
				"relaunch past the cap pushes out (%.2f m/s)" % speed)
		else:
			_check(hit and speed < p2.tuning.loop_pushout_speed, "relaunch under the cap juggles (%.2f m/s)" % speed)


## Put `f` into a knockdown: airborne (rising at `vy`) or about to land.
func _knock_down(f: Fighter, airborne: bool, vy: float = 3.0) -> void:
	f._enter(Fighter.State.KNOCKDOWN)
	f._land_frame = -1
	f.global_position.y = 1.0 if airborne else 0.0
	f._vel = Vector3(0, vy if airborne else 0.0, 0)


func _test_air_tech() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	var t := p2.tuning
	_knock_down(p2, true)
	_src(d, 1).flick(t.air_tech_min_frames - 10, InputFrame.Dodge.BACK)  # too early: expires
	_run(d, t.air_tech_min_frames)
	_check(p2.current_state_name() == &"knockdown", "air tech flick before the window does nothing")
	var start := p2.global_position
	_src(d, 1).flick(d.tick + 1 - _src(d, 1).start_tick, InputFrame.Dodge.LEFT)
	_run(d, 1)
	_check(p2.current_state_name() == &"dodge" and p2.dodge_kind() == Fighter.DodgeKind.AIR_TECH and p2.is_invulnerable(),
		"dodge flick in the air flips out (air tech, invulnerable)")
	var landed := _run_until(d, func() -> bool: return not p2.is_airborne(), 120)
	_run(d, 1)
	var away := (p2.global_position - start).dot(-(d.fighters[0].global_position - start).normalized())
	_check(landed and p2.current_state_name() == &"idle" and p2.lying_frames() < 0 and away > 0.0,
		"air tech lands on the feet, away from the opponent (%s, %.2f m)" % [p2.current_state_name(), away])


func _test_quick_rise() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	var t := p2.tuning
	_knock_down(p2, false)
	_run(d, 2)
	_src(d, 1).press(t.knockdown_min_frames + 2, B.LIGHT)
	var rose := _run_until(d, func() -> bool: return p2.current_state_name() == &"wakeup", t.knockdown_frames)
	_check(rose and p2.state_frame() <= 1 and _event_count(&"wakeup", 1) == 1, "button while lying rises early")
	_run(d, 30)
	_check(p2.current_move() == null, "quick-rise button doesn't also attack")


func _test_wakeup_roll() -> void:
	for dir: InputFrame.Dodge in [InputFrame.Dodge.LEFT, InputFrame.Dodge.BACK]:
		var d := _new_match()
		var p2 := d.fighters[1]
		var t := p2.tuning
		_knock_down(p2, false)
		_run(d, 2)
		var start := p2.global_position
		_src(d, 1).flick(t.knockdown_min_frames + 2, dir)
		var rolled := _run_until(d, func() -> bool: return p2.current_state_name() == &"dodge", t.knockdown_frames)
		_check(rolled and p2.dodge_kind() == Fighter.DodgeKind.ROLL and p2.is_invulnerable(), "flick while lying rolls (%d)" % dir)
		_run(d, maxi(t.sway_move_frames, t.backflip_move_frames) + 2)
		_check(p2.global_position.distance_to(start) > 1.0, "roll moves (%.2f m)" % p2.global_position.distance_to(start))


func _test_stay_down() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	_knock_down(p2, false)
	_run_until(d, func() -> bool: return p2.lying_frames() >= 0, 10)
	_run(d, p2.tuning.knockdown_frames - 1)
	var down := p2.current_state_name() == &"knockdown"
	_run(d, 2)
	_check(down and p2.current_state_name() == &"wakeup", "no input stays down knockdown_frames, then gets up")


func _test_dodge_chain() -> void:
	var d := _new_match(3.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	var s := _src(d, 0)
	s.flick(0, InputFrame.Dodge.BACK).flick(5, InputFrame.Dodge.BACK)  # too early: expires
	_run(d, t.backflip_chain_from_frame + 2)
	_check(_event_count(&"dodge", 0) == 1, "backflip flick before backflip_chain_from_frame doesn't chain")
	# Back-sways chain with no cap (GH), each leaving a vulnerable gap.
	d = _new_match(3.0)
	p1 = d.fighters[0]
	s = _src(d, 0)
	var n := 6
	var at := 0
	for i in n:
		s.flick(at, InputFrame.Dodge.BACK)
		at += t.backflip_chain_from_frame + 1
	_run(d, t.dodge_invuln_start + t.backflip_invuln_frames + 2)
	_check(p1.current_state_name() == &"dodge" and not p1.is_invulnerable(),
		"backflip is punishable between its invuln end and its chain frame")
	_run(d, at)
	_check(_event_count(&"dodge", 0) == n, "back-sways chain without a cap (%d dodges)" % _event_count(&"dodge", 0))
	# Ducks re-chain much sooner than back-sways.
	d = _new_match(3.0)
	s = _src(d, 0)
	at = 0
	for i in n:
		s.flick(at, InputFrame.Dodge.FORWARD)
		at += t.duck_chain_from_frame + 1
	_run(d, at)
	_check(_event_count(&"dodge", 0) == n, "ducks chain every %d frames (%d dodges)" % [t.duck_chain_from_frame + 1, _event_count(&"dodge", 0)])
	# A positive dodge_chain_max still caps the chain.
	var cap := t.dodge_chain_max
	t.dodge_chain_max = 2
	d = _new_match(3.0)
	s = _src(d, 0)
	at = 0
	for i in t.dodge_chain_max + 2:
		s.flick(at, InputFrame.Dodge.FORWARD)
		at += t.duck_chain_from_frame + 1
	_run(d, at)
	var capped := _event_count(&"dodge", 0)
	t.dodge_chain_max = cap
	_check(capped == 3, "dodge_chain_max = 2 allows 3 dodges in a row (%d)" % capped)


## Each dodge direction lasts its own total (GH-measured duck < sway < back-sway).
func _test_dodge_lengths() -> void:
	for dir: InputFrame.Dodge in [InputFrame.Dodge.FORWARD, InputFrame.Dodge.LEFT, InputFrame.Dodge.BACK]:
		var d := _new_match(3.0)
		var p1 := d.fighters[0]
		var t := p1.tuning
		var want: int = {InputFrame.Dodge.FORWARD: t.duck_total_frames, InputFrame.Dodge.LEFT: t.sway_total_frames,
			InputFrame.Dodge.BACK: t.backflip_total_frames}[dir]
		_src(d, 0).flick(0, dir)
		_run_until(d, func() -> bool: return p1.current_state_name() == &"dodge", 5)
		var frames := 0  # ticks spent in the dodge state
		while p1.current_state_name() == &"dodge" and frames < want * 2:
			frames += 1
			d.step()
		_check(frames == want, "dodge %d lasts %d frames (got %d)" % [dir, want, frames])


func _test_dodge_queued_attack() -> void:
	var d := _new_match(3.0)
	var p1 := d.fighters[0]
	var t := p1.tuning
	_src(d, 0).flick(0, InputFrame.Dodge.LEFT).press(3, B.LIGHT)
	var frame := -1
	for i in 40:
		var was := p1.state_frame() if p1.current_state_name() == &"dodge" else -1
		d.step()
		if p1.current_state_name() == &"attack":
			frame = was + 1
			break
	_check(frame == t.sway_attack_from_frame, "attack pressed mid-sway fires on frame %d (got %d)" % [t.sway_attack_from_frame, frame])


## Save, simulate a busy exchange, load, re-simulate: states must match.
func _test_determinism() -> void:
	var d := _new_match()
	d.fighters[0].ki = d.fighters[0].ki_max()
	d.fighters[1].ki = d.fighters[1].ki_max()
	_run(d, 5)
	var snap := d.save_state()
	var prev := [_src(d, 0).snapshot(), _src(d, 1).snapshot()]
	var s0 := _src(d, 0)
	var s1 := _src(d, 1)
	var base := d.tick + 1 - s0.start_tick
	s0.press(base, B.LIGHT).press(base + 4, B.LIGHT).press(base + 8, B.TELEPORT).press(base + 30, B.LIGHT) \
		.press(base + 34, B.LIGHT).press(base + 38, B.HEAVY).stick(base + 80, base + 100, Vector2(0.5, 1)) \
		.press(base + 110, B.HEAVY, 50).stick(base + 160, base + 161, Vector2(0, -1)).press(base + 160, B.HEAVY)
	s1.press(base + 20, B.GUARD, 10).flick(base + 45, InputFrame.Dodge.LEFT).press(base + 70, B.LIGHT) \
		.press(base + 74, B.LIGHT).press(base + 110, B.CHARGE, 20)
	_run(d, 200)
	var first := var_to_str(d.save_state())
	d.load_state(snap)
	s0.restore(prev[0])
	s1.restore(prev[1])
	_run(d, 200)
	var second := var_to_str(d.save_state())
	_check(first == second, "save/load re-simulation is deterministic")
	_check(d.fighters[1].health < d.fighters[1].tuning.max_health, "determinism scenario actually fought")


## Same, through air stalls, an air beam, a dive kick and a duck kick.
func _test_determinism_air() -> void:
	var d := _new_match(4.0)
	d.fighters[0].ki = d.fighters[0].ki_max()
	_run(d, 5)
	var snap := d.save_state()
	var prev := [_src(d, 0).snapshot(), _src(d, 1).snapshot()]
	var s0 := _src(d, 0)
	var s1 := _src(d, 1)
	var base := d.tick + 1 - s0.start_tick
	s0.press(base, B.JUMP).press(base + 8, B.HEAVY).press(base + 60, B.JUMP).press(base + 66, B.SPECIAL) \
		.stick(base + 66, base + 67, Vector2(0, 1)).flick(base + 240, InputFrame.Dodge.FORWARD).press(base + 241, B.HEAVY)
	s1.press(base + 30, B.JUMP).press(base + 36, B.HEAVY).stick(base + 200, base + 230, Vector2(0, 1))
	_run(d, 280)
	var first := var_to_str(d.save_state())
	d.load_state(snap)
	s0.restore(prev[0])
	s1.restore(prev[1])
	_run(d, 280)
	var second := var_to_str(d.save_state())
	_check(first == second, "save/load re-simulation is deterministic (air moves, duck kick)")


## Same, through throws, guard poses, taunts, smashes and steered teleports.
func _test_determinism_bt3() -> void:
	var d := _new_match()
	d.fighters[0].ki = d.fighters[0].ki_max()
	d.fighters[1].ki = 30.0
	_run(d, 5)
	var snap := d.save_state()
	var prev := [_src(d, 0).snapshot(), _src(d, 1).snapshot()]
	var s0 := _src(d, 0)
	var s1 := _src(d, 1)
	var base := d.tick + 1 - s0.start_tick
	s0.press(base, B.THROW).press(base + 60, B.LIGHT).press(base + 68, B.TELEPORT).stick(base + 68, base + 80, Vector2(1, 0)) \
		.press(base + 90, B.LIGHT, 45).stick(base + 90, base + 140, Vector2(0, -1)).press(base + 200, B.HEAVY)
	s1.press(base + 120, B.TAUNT).press(base + 180, B.GUARD, 60) \
		.stick(base + 180, base + 240, Vector2(0, 1))
	var states := {}
	for i in 260:
		d.step()
		states[d.fighters[0].current_state_name()] = true
		states[d.fighters[1].current_state_name()] = true
	var first := var_to_str(d.save_state())
	d.load_state(snap)
	s0.restore(prev[0])
	s1.restore(prev[1])
	_run(d, 260)
	var second := var_to_str(d.save_state())
	_check(first == second, "save/load re-simulation is deterministic (throws, poses, taunts)")
	_check(states.has(&"throw") and states.has(&"thrown"), "determinism scenario threw (%s)" % [states.keys()])
