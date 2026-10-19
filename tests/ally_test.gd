extends Node
## Headless tests for the co-op CPU ally (CpuBrain on team 0): it walks to and
## revives a downed human, holds off while an enemy holds a melee token on it
## near the downed human (until the bleed-out gets desperate), never targets
## entering fighters, its attacks aren't token-gated, it regroups instead of
## wandering off, and a save/load mid-revive re-simulates identically.
## Run as a scene:
##   godot --headless res://tests/ally_test.tscn
##
## Like encounter_test, the encounter is switched on by hand on an ordinary
## match and team-0 fighters are made downable, so these tests don't depend
## on the co-op run flow.

const K := EncounterDirector.Kind
const S := Fighter.State
const HUMAN := 0
const ALLY := 1
const LEVEL := 4

var _failures := 0
var _events: Array = []  # [kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_revives_downed_human, _test_no_revive_while_token_held, _test_desperate_revive,
		_test_targets_and_tokens, _test_regroups, _test_save_load_mid_revive,
	]
	for t in tests:
		t.call()
	print("ALLY TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Slot 0: scripted human, slot 1: CPU ally (team 0, LEVEL), then one
## scripted (idle) enemy per `enemy_pos`. Tokens on, team 0 downable.
func _new_match(ally_pos: Vector3, enemy_pos: Array[Vector3]) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.rng_seed = 5
	var n := 2 + enemy_pos.size()
	for i in n:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = 0 if i < 2 else 1
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = LEVEL
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	d.encounter.enabled = true
	for i in n:
		if i != ALLY:
			d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	var pos: Array[Vector3] = [Vector3.ZERO, ally_pos]
	pos.append_array(enemy_pos)
	for i in n:
		var f := d.fighters[i]
		f.downable = f.team == 0
		f.reset_for_round(Transform3D(Basis.looking_at(Vector3.FORWARD), pos[i]))
		f.event.connect(func(kind: StringName, data: Dictionary) -> void: _events.append([kind, data]))
		if d.sources[i] is ScriptedInput:
			(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	for f in d.fighters:
		f.target = d.pick_default_target(f)
	return d


func _down(f: Fighter) -> void:
	f._set_health(0.0)
	f._enter_ko(Vector3.ZERO)


func _count(kind: StringName, slot: int = -1) -> int:
	var n := 0
	for e: Array in _events:
		if e[0] == kind and (slot < 0 or e[1]["slot"] == slot):
			n += 1
	return n


## Step until `cond` holds (or `limit` steps); returns the steps taken.
func _run_until(d: MatchDirector, cond: Callable, limit: int, each: Callable = Callable()) -> int:
	for i in limit:
		if each.is_valid():
			each.call()
		d.step()
		if cond.call():
			return i + 1
	return -1


# --- tests --------------------------------------------------------------------

func _test_revives_downed_human() -> void:
	var d := _new_match(Vector3(6, 0, 2), [Vector3(0, 0, -20)])
	var f := d.fighters
	_down(f[HUMAN])
	var rf := Tuning.coop.revive_frames
	var limit := rf + 360
	var took := _run_until(d, func() -> bool: return not f[HUMAN].is_downed(), limit)
	_check(took > 0, "ally revives a downed human with no enemy near (%d frames, limit %d)" % [took, limit])
	_check(_count(&"revived", HUMAN) == 1 and _events.any(
		func(e: Array) -> bool: return e[0] == &"revived" and e[1]["reviver_slot"] == ALLY),
		"the revive is the ally's")
	_check(_count(&"revive_cancel") == 0 and _count(&"taunt", ALLY) == 0, "one clean revive, no stray taunt")
	_check(not f[HUMAN].is_ko(), "human back on their feet")


## An idle enemy next to the ally / downed human keeps a melee token on the
## ally (renewed every tick; the ally fights it meanwhile, and a hit on the
## enemy drops its token until it asks again): no revive. Once the token
## stops, it revives.
func _test_no_revive_while_token_held() -> void:
	var d := _new_match(Vector3(1.5, 0, 0), [Vector3(1.5, 0, -2.5)])
	var f := d.fighters
	var enemy := f[2]
	_down(f[HUMAN])
	var keep_token := func() -> void:
		enemy.health = enemy.tuning.max_health
		enemy.target = f[ALLY]
		d.encounter.request_token(enemy, f[ALLY], K.MELEE)
	var held := 0
	var frames := 300
	for i in frames:
		keep_token.call()
		d.step()
		if d.encounter.holders(f[ALLY], K.MELEE).has(enemy.slot):
			held += 1
	_check(held > frames / 2, "the enemy holds a melee token on the ally (%d/%d frames)" % [held, frames])
	_check(_count(&"revive_start", HUMAN) == 0 and f[HUMAN].is_downed(), "no revive while the token is held")
	var took := _run_until(d, func() -> bool: return not f[HUMAN].is_downed(), Tuning.coop.revive_frames + 200)
	_check(took > 0, "token gone: the ally revives (%d frames)" % took)


## The same standoff, but held until the bleed-out passes the desperate
## ratio: then the ally revives anyway.
func _test_desperate_revive() -> void:
	var d := _new_match(Vector3(1.5, 0, 0), [Vector3(1.5, 0, -2.5)])
	var f := d.fighters
	var enemy := f[2]
	var brain := (d.sources[ALLY] as CpuInput).brain
	var desperate := lerpf(Tuning.cpu.revive_desperate_bleed_ratio.x, Tuning.cpu.revive_desperate_bleed_ratio.y, brain.skill)
	_down(f[HUMAN])
	var keep_token := func() -> void:
		enemy.health = enemy.tuning.max_health
		enemy.target = f[ALLY]
		d.encounter.request_token(enemy, f[ALLY], K.MELEE)
	var took := _run_until(d, func() -> bool: return f[HUMAN].reviving_slot() == ALLY,
		Tuning.coop.bleed_out_frames, keep_token)
	var at := f[HUMAN].bleed_out_ratio()
	_check(took > 0 and at >= desperate - 0.01, "revive starts only once bleed-out reaches %.2f (at %.2f)" % [desperate, at])
	took = _run_until(d, func() -> bool: return not f[HUMAN].is_downed(), Tuning.coop.revive_frames + 30, keep_token)
	_check(took > 0, "desperate revive completes")


## The ally's target is never an entering enemy, it keeps a valid target, and
## its attacks never wait for tokens.
func _test_targets_and_tokens() -> void:
	var d := _new_match(Vector3(1.5, 0, 0), [Vector3(-3, 0, -3), Vector3(3, 0, -3)])
	var f := d.fighters
	f[3].begin_entry(120)
	var bad := 0
	var attacks := 0
	for i in 240:
		d.step()
		for h in d.fighters:
			if h.team == 0:
				h.health = h.tuning.max_health
		var t := f[ALLY].target
		if t != null and (t.is_entering() or t.is_ko() or t.team == 0):
			bad += 1
		if f[ALLY].state == S.ATTACK:
			attacks += 1
	_check(bad == 0, "ally never targets entering / KO'd / teammates")
	_check(attacks > 0, "ally attacks freely (%d attack frames, no tokens needed)" % attacks)
	_check(d.encounter.request_token(f[ALLY], f[2], K.MELEE) and d.encounter.holds_token(f[ALLY], K.MELEE),
		"tokens never limit the ally")


## Ally far from its human with its target also far from the human: it walks
## back toward the human instead of chasing.
func _test_regroups() -> void:
	var d := _new_match(Vector3(14, 0, 0), [Vector3(14, 0, -12)])
	var f := d.fighters
	var start := f[ALLY].global_position.distance_to(f[HUMAN].global_position)
	for i in 120:
		d.step()
	var after := f[ALLY].global_position.distance_to(f[HUMAN].global_position)
	_check(after < start - 2.0, "ally strayed past the leash walks back (%.1f m -> %.1f m)" % [start, after])


func _test_save_load_mid_revive() -> void:
	var d := _new_match(Vector3(6, 0, 2), [Vector3(0, 0, -20)])
	var f := d.fighters
	_down(f[HUMAN])
	var took := _run_until(d, func() -> bool: return f[HUMAN].revive_progress() > 0.2, 400)
	_check(took > 0 and f[ALLY].current_state_name() == &"revive", "ally mid-revive")
	var saved := d.save_state()
	for i in Tuning.coop.revive_frames:
		d.step()
	var a := var_to_str(d.save_state())
	var revived_a := not f[HUMAN].is_downed()
	d.load_state(saved)
	_check(f[HUMAN].reviving_slot() == ALLY, "load restores the ally's revive")
	for i in Tuning.coop.revive_frames:
		d.step()
	_check(var_to_str(d.save_state()) == a, "re-simulating after load is identical (brain included)")
	_check(revived_a and not f[HUMAN].is_downed(), "and the revive completes both times")
