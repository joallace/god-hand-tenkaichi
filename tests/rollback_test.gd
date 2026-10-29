extends Node
## Rollback tests: MatchDirector.save_state/load_state must rebuild entities
## spawned or freed since the snapshot (EntityFactory) and re-simulate
## identically. Run as a scene:  godot --headless res://tests/rollback_test.tscn

const B := InputFrame.Btn
## Ticks re-simulated after each load.
const RESIM := 90

var _failures := 0
var _spawned: Array[SimEntity] = []
var _removed: Array[SimEntity] = []


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_live_projectiles, _test_load_frees_new_projectile, _test_load_rebuilds_projectile,
		_test_ids_stable, _test_spawn_remove_fighter, _test_cpu_match_round_trip,
	]
	for t in tests:
		t.call()
	print("ROLLBACK TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in the FIGHT phase. scripted: ScriptedInput sources, else CPUs.
func _new_match(scripted: bool, distance: float = 8.0, seed_value: int = 3) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_spawned.clear()
	_removed.clear()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 0
	cfg.rng_seed = seed_value
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 5
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	if scripted:
		for i in 2:
			d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in 2:
		var pos := Vector3(0, 0, distance * 0.5 if i == 0 else -distance * 0.5)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		d.fighters[i].ki = d.fighters[i].ki_max()
	if scripted:
		for i in 2:
			(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	d.entity_spawned.connect(func(e: SimEntity) -> void: _spawned.append(e))
	d.entity_removed.connect(func(e: SimEntity) -> void: _removed.append(e))
	return d


func _src(d: MatchDirector, i: int) -> ScriptedInput:
	return d.sources[i] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _run_until(d: MatchDirector, cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		d.step()
	return cond.call()


func _hash(d: MatchDirector) -> String:
	return var_to_str(d.save_state())


func _count(d: MatchDirector, type: StringName) -> int:
	return d.entities.filter(func(e: SimEntity) -> bool: return e.spawn_type() == type).size()


## P1 fires a beam (neutral SPECIAL), P2 throws ki blasts meanwhile.
func _script_projectiles(d: MatchDirector) -> void:
	_src(d, 0).press(0, B.SPECIAL)
	_src(d, 1).press(1, B.BLAST)


# --- tests ----------------------------------------------------------------------

## Snapshot with a ki blast and a beam in flight; load and re-simulate.
func _test_live_projectiles() -> void:
	var d := _new_match(true)
	_script_projectiles(d)
	var live := func() -> bool: return _count(d, EntityFactory.KI_BLAST) > 0 and _count(d, EntityFactory.BEAM) > 0
	if not _check(_run_until(d, live, 200), "ki blast and beam both in flight"):
		return
	var snap := d.save_state()
	_run(d, RESIM)
	var first := _hash(d)
	d.load_state(snap)
	_run(d, RESIM)
	_check(first == _hash(d), "save/load with live projectiles re-simulates identically")


## Saved before the projectile existed: loading frees it, re-sim respawns it.
func _test_load_frees_new_projectile() -> void:
	var d := _new_match(true)
	_script_projectiles(d)
	d.step()
	var snap := d.save_state()
	var t0 := d.tick
	_run_until(d, func() -> bool: return not d.entities.is_empty(), 60)
	var blast: SimEntity = d.entities[0] if not d.entities.is_empty() else null
	if not _check(blast != null, "a projectile spawned after the snapshot"):
		return
	_removed.clear()
	var later := d.save_state()
	d.load_state(snap)
	_check(d.entities.is_empty(), "load drops entities the snapshot didn't have")
	_check(blast.get_parent() == null and _removed.has(blast), "dropped projectile leaves the tree with entity_removed")
	d.load_state(later)
	_run(d, RESIM)
	var ticks := d.tick - t0
	var first := _hash(d)
	d.load_state(snap)
	_run(d, ticks)
	_check(first == _hash(d), "re-simulation respawns the projectile identically")


## Saved while a projectile flew; it is gone when loading: rebuilt by the factory.
func _test_load_rebuilds_projectile() -> void:
	var d := _new_match(true)
	_src(d, 0).press(0, B.BLAST)
	if not _check(_run_until(d, func() -> bool: return not d.entities.is_empty(), 60), "ki blast spawned"):
		return
	d.step()
	var snap := d.save_state()
	var old: SimEntity = d.entities[0]
	_run(d, RESIM)
	var first := _hash(d)
	_check(d.entities.is_empty(), "ki blast gone before the load")
	_spawned.clear()
	d.load_state(snap)
	var e: KiBlast = d.entities[0] as KiBlast if d.entities.size() == 1 else null
	if not _check(e != null and e != old, "load rebuilds the freed ki blast"):
		return
	_check(e.caster == d.fighters[0] and e.move != null and e.sim_id == old.sim_id, "rebuilt ki blast relinks caster, move and id")
	_check(_spawned.has(e), "rebuilt projectile announced with entity_spawned")
	_check(var_to_str(e.save_state()) == var_to_str(snap["entities"][0]["state"]), "rebuilt ki blast carries the saved state")
	_run(d, RESIM)
	_check(first == _hash(d), "re-simulation after the rebuild is identical")


## sim_ids: fighters first in slot order, then spawn order; never reused.
func _test_ids_stable() -> void:
	var d := _new_match(true)
	_check(d.fighters[0].sim_id == 1 and d.fighters[1].sim_id == 2, "fighters get ids 1, 2")
	_src(d, 0).press(0, B.BLAST).press(40, B.BLAST)
	var ids: Array[int] = []
	for i in 120:
		d.step()
		for e in d.entities:
			if not ids.has(e.sim_id):
				ids.append(e.sim_id)
	_check(ids.size() == 2 and ids[0] > 2 and ids[1] > ids[0], "projectile ids increase and aren't reused (%s)" % [ids])


## A CPU fighter joining mid-match, then leaving; snapshots across both.
func _test_spawn_remove_fighter() -> void:
	var d := _new_match(false, 3.0)
	_run(d, 30)
	var snap_two := d.save_state()
	var f := d.spawn_fighter(2, &"brawler", 4)
	if not _check(f != null and d.fighters.size() == 3 and d.sources[2] is CpuInput, "spawn_fighter adds a CPU fighter with its own source"):
		return
	_check(_spawned.has(f) and f.sim_id == snap_two["next_sim_id"], "spawned fighter announced, next id")
	_check(d.spawn_fighter(2, &"brawler", 4) == null, "spawn_fighter refuses a used slot")
	f.reset_for_round(Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)))
	_run(d, 30)
	var snap_three := d.save_state()
	_run(d, RESIM)
	var first := _hash(d)
	d.remove_fighter(f)
	_check(d.fighters.size() == 2 and d.sources.size() == 2 and _removed.has(f), "remove_fighter drops fighter and source")
	_run(d, 20)
	d.load_state(snap_three)
	var back := d.fighter_for_slot(2)
	_check(back != null and back != f and back.sim_id == f.sim_id and d.sources[2] is CpuInput, "load rebuilds the removed fighter with a CPU source")
	_run(d, RESIM)
	_check(first == _hash(d), "re-simulation with the rebuilt fighter is identical")
	d.load_state(snap_two)
	_check(d.fighters.size() == 2 and d.fighter_for_slot(2) == null and d.sources.size() == 2, "loading an older snapshot drops the spawned fighter")
	_run(d, 10)
	_check(d.fighters[0].target == d.fighters[1], "1v1 links survive the round trip")


## Long CPU vs CPU fight (projectiles come and go): save, re-simulate, compare.
func _test_cpu_match_round_trip() -> void:
	var d := _new_match(false, 6.0, 11)
	var spawned_any := false
	for i in 600:
		d.step()
		spawned_any = spawned_any or not d.entities.is_empty()
	var snap := d.save_state()
	for i in 300:
		d.step()
		spawned_any = spawned_any or not d.entities.is_empty()
	var first := _hash(d)
	d.load_state(snap)
	_run(d, 300)
	_check(first == _hash(d), "CPU vs CPU save/load re-simulation is identical")
	print("  (projectiles seen in CPU fight: %s)" % spawned_any)
