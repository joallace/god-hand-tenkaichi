extends Node
## Headless CPU AI tests: CPU vs CPU and CPU vs scripted attackers. Run as a
## scene:  godot --headless res://tests/cpu_test.tscn

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_fights, _test_levels_ordered, _test_defense_scales, _test_perfect_dodge,
		_test_vanish_battle_response, _test_knockdown_options, _test_guard_pose, _test_throw_break,
		_test_throws_turtle, _test_determinism, _test_save_load, _test_full_match,
	]
	for t in tests:
		t.call()
	print("CPU TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in the FIGHT phase. `levels[i]` < 0 = scripted (ScriptedInput) slot.
func _new_match(levels: Array, seed_value: int = 1, distance: float = -1.0) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 0
	cfg.rng_seed = seed_value
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = maxi(levels[i], 0)
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in 2:
		if levels[i] < 0:
			d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in 2:
		if distance > 0.0:
			var pos := Vector3(0, 0, distance * 0.5 if i == 0 else -distance * 0.5)
			d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		d.fighters[i].event.connect(func(kind: StringName, data: Dictionary) -> void:
			_events.append([i, kind, data]))
		if d.sources[i] is ScriptedInput:
			(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		if d.phase != MatchDirector.Phase.FIGHT:
			return
		d.step()


func _count(kind: StringName, slot: int = -1, pred: Callable = Callable()) -> int:
	var n := 0
	for e in _events:
		if e[1] == kind and (slot < 0 or e[0] == slot) and (not pred.is_valid() or pred.call(e[2])):
			n += 1
	return n


## Hits (not blocked) taken by `slot`.
func _hits_taken(slot: int) -> int:
	return _count(&"hit", slot, func(data: Dictionary) -> bool: return not data["blocked"])


func _summary(label: String, d: MatchDirector) -> void:
	var kinds := {}
	for e in _events:
		var k := "%s/%d" % [e[1], e[0]]
		kinds[k] = kinds.get(k, 0) + 1
	print("  [%s] hp %.0f / %.0f  %s" % [label, d.fighters[0].health, d.fighters[1].health, kinds])


## A scripted attacker (slot 0) repeating `pattern` every `period` ticks.
func _script_attacks(d: MatchDirector, ticks: int, period: int, pattern: Callable) -> void:
	var s := d.sources[0] as ScriptedInput
	var at := 10
	while at < ticks:
		pattern.call(s, at)
		at += period


# --- tests ----------------------------------------------------------------------

func _test_fights() -> void:
	var d := _new_match([4, 4])
	_run(d, 1800)
	_summary("normal vs normal", d)
	var dealt := 0
	for i in 2:
		dealt += _hits_taken(i)
	_check(dealt >= 6, "two CPUs actually fight (%d clean hits)" % dealt)
	_check(_count(&"hit", -1, func(data: Dictionary) -> bool: return data["blocked"]) > 0
			or _count(&"dodge") > 0, "CPUs defend (blocks or dodges)")


## Over several seeds the strongest level beats the weakest on damage.
func _test_levels_ordered() -> void:
	var top := Tuning.cpu.level_count() - 1
	var wins := 0
	var runs := 4
	for seed_value in runs:
		var d := _new_match([0, top], seed_value + 10)
		_run(d, 2400)
		_summary("lvl0 vs lvl%d seed %d" % [top, seed_value], d)
		if d.fighters[1].health_ratio() > d.fighters[0].health_ratio():
			wins += 1
	_check(wins >= runs - 1, "top level out-damages bottom level (%d/%d)" % [wins, runs])


## Defense only: the CPU in `slot` never starts anything on its own.
func _make_passive(d: MatchDirector, slot: int) -> void:
	var brain := (d.sources[slot] as CpuInput).brain
	var c := brain.cfg.duplicate() as CpuTuning
	c.aggression = Vector2.ZERO
	c.punish_chance = Vector2.ZERO
	c.charge_chance = Vector2.ZERO
	c.blast_chance = Vector2.ZERO
	c.special_chance = Vector2.ZERO
	c.think_interval = Vector2(100000, 100000)
	brain.cfg = c


## Scripted heavies (stick forward / neutral / back in turn) against a passive
## CPU; the attacker re-closes the distance. Returns clean hits per attack.
func _heavy_pressure(lvl: int, seed_value: int) -> float:
	var d := _new_match([-1, lvl], seed_value, 1.8)
	_make_passive(d, 1)
	var s := d.sources[0] as ScriptedInput
	var attacks := 0
	var n := 0
	while n < 2400:
		var y: float = [1.0, 0.0, -1.0][attacks % 3]
		s.stick(n, n + 40, Vector2(0, 1)).stick(n + 40, n + 41, Vector2(0, y)).press(n + 40, B.HEAVY)
		attacks += 1
		n += 90
	_run(d, 2400)
	_summary("heavies vs passive lvl%d" % lvl, d)
	return _hits_taken(1) / float(attacks)


func _test_defense_scales() -> void:
	var weak := _heavy_pressure(0, 3)
	var strong := _heavy_pressure(Tuning.cpu.level_count() - 1, 3)
	_check(strong < weak * 0.5, "strong CPU gets hit far less than weak (%.2f vs %.2f hits/attack)" % [strong, weak])


func _test_perfect_dodge() -> void:
	_heavy_pressure(Tuning.cpu.level_count() - 1, 5)
	_check(_count(&"perfect_dodge", 1) > 0, "top CPU lands perfect dodges")
	_check(_count(&"stagger", 0) > 0, "top CPU perfect-ducks highs (attacker staggered)")


## The scripted player vanish-escapes out of the CPU's hits; strong CPUs
## answer the vanish, the weakest can't react inside the window.
func _vanish_answers(lvl: int) -> int:
	var answered := 0
	for seed_value in 4:
		var d := _new_match([-1, lvl], 20 + seed_value, 1.4)
		var s := d.sources[0] as ScriptedInput
		var escaped := false
		for i in 600:
			d.fighters[0].ki = d.fighters[0].ki_max()
			d.fighters[1].ki = d.fighters[1].ki_max()
			if not escaped and d.fighters[0].current_state_name() == &"hitstun":
				s.press_at_tick(d.tick + 1, B.TELEPORT)
				escaped = true
			d.step()
			if escaped and _count(&"vanish_battle_end") > 0:
				break
		answered += _count(&"vanish", 1)
	return answered


## Knock a passive CPU down `trials` times (launched, or flat on the floor).
## Returns how often it took an option: air tech (never lay down) when
## launched, an early get-up (rise/roll before knockdown_frames) when flat.
func _knockdown_options(lvl: int, airborne: bool, trials: int) -> int:
	var d := _new_match([-1, lvl], 40 + lvl, 3.0)
	_make_passive(d, 1)
	var f := d.fighters[1]
	var taken := 0
	for i in trials:
		f._enter(Fighter.State.KNOCKDOWN)
		f._land_frame = -1
		f.global_position.y = 1.0 if airborne else 0.0
		f._vel = Vector3(0, 6.0 if airborne else 0.0, 0)
		var longest := -1
		for k in 150:
			d.step()
			longest = maxi(longest, f.lying_frames())
			if f.current_state_name() == &"idle":
				break
		if airborne and longest < 0 or not airborne and longest < f.tuning.knockdown_frames - 1:
			taken += 1
	return taken


func _test_knockdown_options() -> void:
	var top := Tuning.cpu.level_count() - 1
	var techs := _knockdown_options(top, true, 8)
	_check(techs >= 4 and _knockdown_options(0, true, 8) == 0, "top CPU air techs launches, weakest never (%d/8)" % techs)
	var rises := _knockdown_options(top, false, 8)
	var weak_rises := _knockdown_options(0, false, 8)
	_check(rises >= 4 and weak_rises < rises, "top CPU gets up early more often (%d/8 vs %d/8)" % [rises, weak_rises])


func _test_vanish_battle_response() -> void:
	var strong := _vanish_answers(Tuning.cpu.level_count() - 1)
	var weak := _vanish_answers(0)
	_check(strong >= 3, "top CPU answers vanishes (%d exchanges over 4 battles)" % strong)
	_check(weak < strong, "weakest CPU answers fewer vanishes (%d < %d)" % [weak, strong])


## Passive CPU that only guards (no dodges, vanishes or counters).
func _make_guarder(d: MatchDirector, slot: int) -> void:
	_make_passive(d, slot)
	var c := (d.sources[slot] as CpuInput).brain.cfg
	c.dodge_preference = Vector2.ZERO
	c.guard_vanish_chance = Vector2.ZERO
	c.counter_guard_chance = Vector2.ZERO


## Scripted low kicks (stick back + HEAVY): a top CPU guards low, which
## repels them (push-off); the weakest mostly stays in a mid ki guard. The
## guarder's ki is kept empty: with ki a late fresh GUARD press would vanish,
## so the CPU dodges instead.
func _low_guards(lvl: int) -> Array[int]:
	var d := _new_match([-1, lvl], 6, 1.8)
	_make_guarder(d, 1)
	var s := d.sources[0] as ScriptedInput
	var n := 0
	while n < 1800:
		s.stick(n, n + 40, Vector2(0, 1)).stick(n + 40, n + 41, Vector2(0, -1)).press(n + 40, B.HEAVY)
		n += 90
	for i in 1800:
		d.fighters[1].ki = 0.0
		d.step()
	_summary("low kicks vs guarding lvl%d" % lvl, d)
	var blocked := _count(&"hit", 1, func(data: Dictionary) -> bool: return data["blocked"])
	return [_count(&"push_off", 1), blocked]


func _test_guard_pose() -> void:
	var top := _low_guards(Tuning.cpu.level_count() - 1)
	var weak := _low_guards(0)
	_check(top[1] >= 5 and top[0] >= top[1] * 0.7,
			"top CPU guards low vs low kicks (%d push-offs / %d blocks)" % [top[0], top[1]])
	_check(top[0] > weak[0], "weakest CPU picks the low guard less (%d vs %d push-offs)" % [weak[0], top[0]])


## Scripted grabs against a guarding CPU. Returns [grabs, breaks].
func _throw_breaks(lvl: int) -> Array[int]:
	var d := _new_match([-1, lvl], 8, 1.8)
	_make_guarder(d, 1)
	var s := d.sources[0] as ScriptedInput
	var n := 0
	while n < 2400:
		s.stick(n, n + 40, Vector2(0, 1)).press(n + 40, B.THROW)
		n += 120
	_run(d, 2400)
	_summary("grabs vs lvl%d" % lvl, d)
	return [_count(&"throw", 0), _count(&"throw_break", 1)]


func _test_throw_break() -> void:
	var top := _throw_breaks(Tuning.cpu.level_count() - 1)
	var weak := _throw_breaks(0)
	_check(top[0] >= 5 and top[1] >= 3, "top CPU breaks throws (%d of %d grabs)" % [top[1], top[0]])
	_check(weak[0] >= 5 and weak[1] == 0, "weakest CPU never breaks throws (%d of %d grabs)" % [weak[1], weak[0]])


## A scripted turtle that only holds GUARD gets thrown by a strong CPU.
func _test_throws_turtle() -> void:
	var d := _new_match([-1, Tuning.cpu.level_count() - 2], 12, 1.6)
	var s := d.sources[0] as ScriptedInput
	s.press(0, B.GUARD, 1200)
	_run(d, 1200)
	_summary("vs turtle", d)
	_check(_count(&"throw", 1) > 0, "CPU throws a turtling opponent (%d throws)" % _count(&"throw", 1))


func _test_determinism() -> void:
	var states: Array[String] = []
	for i in 2:
		var d := _new_match([5, 3], 77)
		_run(d, 1500)
		states.append(var_to_str([d.fighters[0].save_state(), d.fighters[1].save_state()]))
	_check(states[0] == states[1], "CPU vs CPU with the same seed is deterministic")


func _test_save_load() -> void:
	var d := _new_match([6, 6], 9)
	_run(d, 300)
	var cpu := d.sources[0] as CpuInput
	var snap := cpu.save_state()
	var a := cpu.brain.think()
	var after_a := var_to_str(cpu.brain.save_state())
	cpu.load_state(snap)
	var b := cpu.brain.think()
	_check(a.equals(b) and after_a == var_to_str(cpu.brain.save_state()), "CPU brain state round-trips save/load")


## Whole match through round transitions with the real timer.
func _test_full_match() -> void:
	for c in get_children():
		c.queue_free()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 30
	cfg.rng_seed = 4
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = Tuning.cpu.level_count() - 1 - i * 2
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	var ended := [false]
	d.match_ended.connect(func(_w: int) -> void: ended[0] = true)
	for i in 60 * 60 * 4:
		d.step()
		if ended[0]:
			break
	print("  full match: rounds %d wins %s" % [d.round_number, d.wins])
	_check(ended[0], "CPU vs CPU plays a whole match to the end")
