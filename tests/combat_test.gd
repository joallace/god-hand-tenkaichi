extends Node
## Headless combat tests with scripted inputs. Run as a scene:
##   godot --headless res://tests/combat_test.tscn
## Prints PASS/FAIL per check and exits with 0 only if all pass.

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_light_hit, _test_light_string, _test_guard, _test_guard_break,
		_test_dodge_invuln, _test_perfect_dodge, _test_charge, _test_teleport,
		_test_vanish_battle, _test_ki_blast, _test_beam, _test_rush, _test_ultimate,
		_test_not_enough_ki, _test_jump_attack, _test_strike_heights, _test_height_vs_duck,
		_test_charge_strike_release, _test_charge_strike_stun, _test_charge_strike_guard,
		_test_charge_punch, _test_heavy_at_range_blast, _test_charge_heavy_special,
		_test_guard_teleport, _test_guard_vanish_escape, _test_guard_vanish, _test_determinism,
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
	var dmg := d.fighters[1].tuning.max_health - d.fighters[1].health
	_check(dmg < 30.0 + 30.0 + 40.0 + 55.0 + 0.01, "combo damage is scaled (%.1f)" % dmg)
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
	_check(p2.guard_health < p2.tuning.guard_health, "guard health drained")


func _test_guard_break() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	p2.guard_health = 10.0
	_src(d, 1).press(0, B.GUARD, 80)
	_src(d, 0).press(2, B.HEAVY)
	var broke := _run_until(d, func() -> bool: return p2.current_state_name() == &"guard_break", 60)
	_check(broke and _event_count(&"guard_break", 1) == 1, "heavy breaks a weakened guard")


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
	_check(p1.current_state_name() == &"idle", "releasing CHARGE exits")


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
	_check(_event_count(&"ultimate_start", 0) == 1 and d.hitstop > 0, "ultimate emits ultimate_start and freezes")
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
			_check(is_equal_approx(p2.ki, p2.ki_max() - VanishBattle.cost_for(p2.tuning, 0)), "guard vanish costs ki")


func _test_jump_attack() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.JUMP).press(8, B.LIGHT)
	var air := _run_until(d, func() -> bool: return p1.is_airborne(), 5)
	_check(air, "jump leaves the ground")
	_run(d, 60)
	_check(p2.health < p2.tuning.max_health and p1.global_position.y == 0.0, "jumping attack hits and lands")


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
			_check(_event_count(&"guard_break", 1) == 1 and p2.current_state_name() == &"guard_break",
				"full charge breaks a full guard")
		else:
			_check(_event_count(&"guard_break", 1) == 0 and p2.current_state_name() == &"guard_stun",
				"half charge is blocked (guard %.1f)" % p2.guard_health)
			_check(p2.guard_health < p2.tuning.guard_health - m.guard_damage, "charge scales guard damage")


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
