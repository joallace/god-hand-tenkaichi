extends Node
## Gameplay roadmap stage 1 (docs/gameplay_roadmap.md): the BT3 rules stage 0
## confirmed in the port, held to the sim. Run as a scene:
##   godot --headless res://tests/stage1_rules_test.tscn
## - the Z-counter (timed GUARD vanish) works on smashes / finishers, never on
##   string hits;
## - a smash under way absorbs light hits (armor) and still comes out;
## - a full-charge smash is ki-guarded at about half a bar, never crashes;
## - momentum: landed hits speed up the next charge, briefly; it round-trips
##   through save_state / load_state;
## - the approach lunge stops at contact; light hits have no hitstop; the
##   defender gains no ki from being hit; a jab is ~0.75% of health.

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_jab_not_z_counterable, _test_heavy_z_counter, _test_smash_armor, _test_full_smash_ki_guard,
		_test_momentum, _test_momentum_save_load, _test_lunge_stops_at_contact, _test_light_hit_numbers,
		_test_guarded_ender_stuck,
	]
	for t in tests:
		t.call()
	print("STAGE1 RULES TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
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


func _last_event(kind: StringName, slot: int = -1) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i][1] == kind and (slot < 0 or _events[i][0] == slot):
			return _events[i][2]
	return {}


func _move_id(f: Fighter) -> StringName:
	return f.current_move().id if f.current_move() else &""


# --- tests ----------------------------------------------------------------------

## GUARD pressed just before a jab: a plain guard, never a vanish (BT3: the
## same press is a guard against a rush hit).
func _test_jab_not_z_counterable() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	var jab := p1.def.move(p1.def.light_string[0])
	_check(not jab.z_counterable, "jab is not z_counterable")
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 1).press(maxi(jab.startup - 2, 0), B.GUARD, 60)
	_run(d, 40)
	_check(_event_count(&"vanish", 1) == 0 and _event_count(&"hit", 1) == 1 and _last_event(&"hit", 1)["blocked"],
		"timed GUARD against a jab blocks, no vanish")
	_check(is_equal_approx(p2.ki, p2.ki_max()), "no ki spent on a jab guard")


## The close neutral HEAVY (body blow) is a finisher-class hit: a GUARD
## pressed 2 frames before it lands vanishes behind the attacker.
func _test_heavy_z_counter() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	var heavy := p1.def.move(p1.def.heavy)
	_check(heavy.z_counterable, "close heavy is z_counterable")
	_src(d, 0).press(0, B.HEAVY)
	_src(d, 1).press(heavy.startup - 2, B.GUARD, 60)
	_run(d, 50)
	_check(_event_count(&"vanish", 1) == 1 and _event_count(&"hit", 1) == 0, "timed GUARD vanishes through a heavy")
	for id: StringName in [&"brawler_charge_punch", &"brawler_smash_up", &"brawler_finisher", &"brawler_finisher_1"]:
		_check(p1.def.move(id).z_counterable, "%s is z_counterable" % id)
	for id: StringName in p1.def.light_string:
		_check(not p1.def.move(id).z_counterable, "%s is not z_counterable" % id)


## A smash being charged takes a jab without being interrupted (armor), then
## comes out and lands.
func _test_smash_armor() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var t := p1.tuning
	var smash := p1.def.move(&"brawler_charge_punch")
	_check(smash.armor_hits > 0, "charged smash has armor")
	# Hold LIGHT: jab1 turns into the charge punch and holds; P2 jabs into it.
	_src(d, 0).press(0, B.LIGHT, t.charge_hold_frames + 30)
	_run_until(d, func() -> bool: return p1.is_charging_strike(), 40)
	_check(p1.is_charging_strike(), "P1 charging the smash")
	_src(d, 1).press_at_tick(d.tick + 1, B.LIGHT)
	var hurt := _run_until(d, func() -> bool: return p1.health < t.max_health, 30)
	_check(hurt and _move_id(p1) == smash.id and p1.current_state_name() == &"attack",
		"the jab hurts P1 but the smash keeps going (%s)" % _move_id(p1))
	_check(_event_count(&"hit", 0) == 1 and _last_event(&"hit", 0)["blocked"], "the jab was absorbed by armor")
	var serial := p1.current_move_serial()
	var landed := _run_until(d, func() -> bool: return p2.health < p2.tuning.max_health, 90)
	_check(landed and p1.current_move_serial() == serial, "the same armored smash lands")


## A full-charge neutral smash into a held guard: ki guard at about half a bar
## (more than the uncharged price), never a guard crash.
func _test_full_smash_ki_guard() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = p2.ki_max()
	var t := p1.tuning
	var smash := p1.def.move(&"brawler_charge_punch")
	_src(d, 1).press(0, B.GUARD, 400)
	_src(d, 0).press(0, B.LIGHT, t.charge_hold_frames + smash.charge_max_frames + 40)
	# The held LIGHT's jab comes out (and is blocked) before it turns into the
	# smash: wait for the smash's own contact.
	var jab_blocked := _run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 40)
	var ki_before := p2.ki
	var blocked := _run_until(d, func() -> bool: return _event_count(&"hit", 1) > 1, 200)
	_check(jab_blocked and is_equal_approx(p1.charge_ratio(), 1.0), "the jab was blocked, then the smash fully charged")
	var spent := ki_before - p2.ki
	var bar := t.ki_bar_size
	_check(blocked and _last_event(&"hit", 1)["blocked"], "full smash blocked")
	_check(_event_count(&"guard_break", 1) == 0, "full smash doesn't crash the guard")
	_check(spent > smash.guard_ki_cost and spent >= 0.4 * bar and spent <= 0.7 * bar,
		"full smash ki guard costs about half a bar (%.1f of %.0f)" % [spent, bar])


## Landed hits fill momentum; it speeds up the charge, then drains.
func _test_momentum() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var t := p1.tuning
	_check(is_equal_approx(p1.charge_rate(), 1.0), "cold charge rate is 1")
	_src(d, 0).press(0, B.LIGHT).press(12, B.LIGHT).press(24, B.LIGHT).press(38, B.LIGHT)
	_run(d, 60)
	_check(p1.combo_hits >= 3, "string landed (%d hits)" % p1.combo_hits)
	var hot := p1.charge_rate()
	_check(hot > 1.2 and hot <= t.momentum_charge_rate_max, "charge rate after a string: %.2f" % hot)
	_run(d, t.momentum_hold_frames + roundi(1.0 / t.momentum_decay_per_frame) + 10)
	_check(is_equal_approx(p1.momentum(), 0.0), "momentum gone a while after the string")
	# A hot charge reaches full in fewer frames than a cold one.
	var frames_hot := _frames_to_full_charge(true)
	var frames_cold := _frames_to_full_charge(false)
	_check(frames_hot < frames_cold and frames_hot >= roundi(frames_cold / t.momentum_charge_rate_max) - 1,
		"hot charge %d frames vs cold %d" % [frames_hot, frames_cold])


func _frames_to_full_charge(hot: bool) -> int:
	var d := _new_match(4.0)
	var p1 := d.fighters[0]
	if hot:
		p1._momentum = 1.0
		p1._since_hit_landed = 0
	_src(d, 0).press(0, B.LIGHT, 200)
	_run_until(d, func() -> bool: return p1.is_charging_strike(), 40)
	if hot:
		p1._momentum = 1.0
		p1._since_hit_landed = 0
	var n := 0
	while p1.is_charging_strike() and p1.charge_ratio() < 1.0 and n < 200:
		d.step()
		n += 1
		if hot:
			p1._since_hit_landed = 0  # keep it hot: measure the rate alone
	return n


func _test_momentum_save_load() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	p1._momentum = 0.625
	p1._charge = 3.5
	var snap := d.save_state()
	var h := StateHash.of(d)
	p1._momentum = 0.0
	p1._charge = 0.0
	d.load_state(snap)
	p1 = d.fighters[0]
	_check(is_equal_approx(p1.momentum(), 0.625) and is_equal_approx(p1._charge, 3.5), "momentum and charge round-trip")
	_check(StateHash.of(d) == h, "state hash unchanged by the round trip")


## A jab from close in barely moves the attacker; from farther it drives in
## (BT3 approach) but stops at contact instead of shoving the victim.
func _test_lunge_stops_at_contact() -> void:
	var travel := {}
	for dist: float in [1.4, 3.0]:
		var d := _new_match(dist)
		var p1 := d.fighters[0]
		var p2 := d.fighters[1]
		var start := p1.global_position
		var p2_start := p2.global_position
		_src(d, 0).press(0, B.LIGHT)
		_run(d, 14)
		travel[dist] = (p1.global_position - start).length()
		if dist > 2.0:
			_check(p2.health < p2.tuning.max_health, "jab from %.1f m drives in and lands" % dist)
			# The jab's own push (knockback 1 m/s) moves P2 a few cm; a lunge
			# driving through would carry it along much farther.
			var shove := (p2.global_position - p2_start).length()
			_check(shove < 0.25, "the far jab doesn't shove the victim (%.2f m)" % shove)
		else:
			_check((p2.global_position - p2_start).length() < 0.25, "close jab doesn't shove the victim")
	_check(travel[1.4] < 0.25 and travel[3.0] > 0.5, "lunge travel close %.2f, far %.2f" % [travel[1.4], travel[3.0]])


## Jab: no hitstop, ~0.75% of health, the victim gains no ki.
func _test_light_hit_numbers() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	p2.ki = 0.0
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) > 0, 30)
	var dmg: float = _last_event(&"hit", 1)["damage"]
	_check(dmg / p2.tuning.max_health > 0.005 and dmg / p2.tuning.max_health < 0.01,
		"jab = %.2f%% of health" % (100.0 * dmg / p2.tuning.max_health))
	_check(p1.hitstop == 0 and p2.hitstop == 0, "no hitstop on a jab")
	_check(is_equal_approx(p2.ki, 0.0), "no ki for taking a hit")


## A guarded ender is stuck in its long recovery: its follow-ups need a hit
## (BT3: rush 5 opens follow-ups only if it landed).
func _test_guarded_ender_stuck() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var ender := p1.def.move(p1.def.light_string[p1.def.light_string.size() - 1])
	_src(d, 1).press(0, B.GUARD, 400)
	var s0 := _src(d, 0)
	s0.press(0, B.LIGHT)
	for i in p1.def.light_string.size() - 1:
		var step := p1.def.move(p1.def.light_string[i])
		_run_until(d, func() -> bool: return _move_id(p1) == step.id and p1.state_frame() >= step.cancel_start - 2, 60)
		s0.press_at_tick(d.tick + 1, B.LIGHT)
	var reached := _run_until(d, func() -> bool: return _move_id(p1) == ender.id, 30)
	_check(reached, "string reaches the ender against a guard")
	# Mash HEAVY through the ender's whole cancel window.
	for k in range(0, ender.cancel_end + 2, 2):
		s0.press_at_tick(d.tick + 1 + k, B.HEAVY)
	var cancelled := false
	for i in ender.total() + 5:
		d.step()
		var id := _move_id(p1)
		if id != &"" and id != ender.id:
			cancelled = true
	_check(_event_count(&"hit", 1) >= 1 and _last_event(&"hit", 1)["blocked"], "the ender was guarded")
	_check(not cancelled, "a guarded ender can't cancel into a follow-up")
