extends Node
## Headless tests for the co-op run flow (CoopRun + MatchDirector Mode.COOP):
## field cap and queue, refills after KO + fade + delay, ring-edge spawns,
## teams/targets/downable, clear / wipe / time-out endings, save/load mid-run,
## arena growth. Run as a scene:
##   godot --headless res://tests/coop_run_test.tscn

var _failures := 0
var _run_end: Array = []  # cleared flags
var _match_end: Array = []  # winner slots


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_build_and_cap, _test_edge_spawn, _test_refill, _test_cleared,
		_test_wipe, _test_time_out, _test_save_load, _test_versus_radius,
	]
	for t in tests:
		t.call()
	print("COOP RUN TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Co-op run with `humans` CPU-driven team-0 players (weakest level, so
## nobody gets beaten up during a test) against `enemies` enemies, in FIGHT.
func _new_run(humans: int, enemies: int, seconds: int = 0) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_run_end.clear()
	_match_end.clear()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = seconds
	cfg.rng_seed = 1234
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = enemies
	cfg.coop.enemy_level = 0
	for i in humans:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 0
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.run_ended.connect(func(c: bool) -> void: _run_end.append(c))
	d.match_ended.connect(func(w: int) -> void: _match_end.append(w))
	d.setup(cfg)
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	return d


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _team(d: MatchDirector, team: int) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in d.fighters:
		if f.team == team:
			out.append(f)
	return out


func _ko(f: Fighter) -> void:
	f.health = 0.0
	f._enter_ko(Vector3.ZERO)


func _hash(d: MatchDirector) -> String:
	return var_to_str(d.save_state())


# --- tests --------------------------------------------------------------------

func _test_build_and_cap() -> void:
	var d := _new_run(2, 10)
	var cap := Tuning.coop.field_cap
	var humans := _team(d, 0)
	var foes := _team(d, 1)
	_check(d.coop != null and d.fighters.size() == cap, "field filled to the cap (%d / %d)" % [d.fighters.size(), cap])
	_check(humans.size() == 2 and foes.size() == cap - 2, "2 humans on team 0, %d enemies on team 1" % foes.size())
	_check(d.coop.enemies_left() == 10, "enemies left counts queued + standing (%d)" % d.coop.enemies_left())
	var slots_ok := true
	for i in foes.size():
		slots_ok = slots_ok and foes[i].slot == 2 + i
	_check(slots_ok, "enemy slots follow the config slots")
	var targets_ok := true
	for f in d.fighters:
		targets_ok = targets_ok and f.target != null and f.target.team != f.team
	_check(targets_ok, "everyone targets the other team")
	_check(humans.all(func(f: Fighter) -> bool: return f.downable) and not foes.any(func(f: Fighter) -> bool: return f.downable),
		"team 0 is downable, enemies aren't")
	var want := Tuning.match_rules.arena_radius + Tuning.coop.arena_radius_per_extra_fighter * (cap - 2)
	_check(is_equal_approx(d.arena_radius, want), "arena grows with the planned field (%.1f m)" % d.arena_radius)
	var r := d.arena_radius - Tuning.fighter.body_radius - Tuning.coop.spawn_edge_inset
	var edge_ok := true
	for f in foes:
		edge_ok = edge_ok and absf(Vector2(f.global_position.x, f.global_position.z).length() - r) < 0.01
	_check(edge_ok, "enemies appear on the ring edge")
	var near_ok := true
	for f in humans:
		near_ok = near_ok and Vector2(f.global_position.x, f.global_position.z).length() <= Tuning.coop.human_spawn_radius + 0.01
	_check(near_ok, "team 0 starts around the centre")


func _test_edge_spawn() -> void:
	var d := _new_run(1, 1)
	var h := _team(d, 0)[0]
	h.global_position = Vector3(0, 0, 6)
	var xf := d.coop._edge_transform(0)
	_check(xf.origin.z < -1.0 and absf(xf.origin.x) < 0.01, "spawn is on the far side from team 0 (%s)" % xf.origin)
	var facing := -xf.basis.z
	_check(facing.dot(-xf.origin.normalized()) > 0.99, "a new enemy faces the centre")
	var a := d.coop._edge_transform(1).origin
	var b := d.coop._edge_transform(2).origin
	_check(a.distance_to(xf.origin) > 1.0 and b.distance_to(xf.origin) > 1.0 and a.x * b.x < 0.0,
		"burst spawns spread to both sides")


func _test_refill() -> void:
	var d := _new_run(2, 10)
	var cap := Tuning.coop.field_cap
	var victim := _team(d, 1)[0]
	var gone_slot := victim.slot
	_ko(victim)
	_run(d, Tuning.coop.enemy_fade_frames - 1)
	_check(d.fighter_for_slot(gone_slot) != null, "a KO'd enemy lingers while it fades")
	_run(d, 1)
	_check(d.fighter_for_slot(gone_slot) == null and d.fighters.size() == cap - 1, "removed after enemy_fade_frames")
	_run(d, Tuning.coop.refill_delay_frames)
	_check(d.fighters.size() == cap - 1, "refill waits refill_delay_frames")
	_run(d, 1)
	_check(d.fighters.size() == cap and d.fighter_for_slot(cap) != null, "refilled with a fresh slot (%d)" % cap)
	_check(d.coop.enemies_left() == 9, "one enemy fewer to beat (%d)" % d.coop.enemies_left())


func _test_cleared() -> void:
	var d := _new_run(1, 2)
	for f in _team(d, 1):
		_ko(f)
	_run(d, 1)
	_check(_run_end == [true], "all enemies beaten -> run cleared")
	_check(d.phase == MatchDirector.Phase.MATCH_OVER and _match_end == [0], "match over, team 0 lead slot wins")


func _test_wipe() -> void:
	var d := _new_run(2, 3)
	for f in _team(d, 0):
		f.health = 0.0
	_run(d, 1)
	_check(_run_end == [false], "team 0 all at 0 HP -> run lost")
	_check(d.phase == MatchDirector.Phase.MATCH_OVER and _match_end == [-1], "match over with no winner slot")


func _test_time_out() -> void:
	var d := _new_run(1, 2, 1)
	_run(d, Tuning.match_rules.tick_rate + 1)
	_check(_run_end == [false], "run time limit -> loss")


func _test_save_load() -> void:
	var d := _new_run(2, 10)
	_run(d, 30)
	var victim := _team(d, 1)[0]
	var slot := victim.slot
	_ko(victim)
	_run(d, 10)
	var snap := d.save_state()
	_run(d, Tuning.coop.enemy_fade_frames + Tuning.coop.refill_delay_frames + 30)
	var a := _hash(d)
	d.load_state(snap)
	_check(d.fighter_for_slot(slot) != null, "load brings back the removed (fading) enemy")
	_run(d, Tuning.coop.enemy_fade_frames + Tuning.coop.refill_delay_frames + 30)
	_check(_hash(d) == a, "mid-run save/load re-sims identically (fade, refill, queue)")


func _test_versus_radius() -> void:
	var cfg := MatchConfig.from_defaults()
	_check(is_equal_approx(MatchDirector.arena_radius_for(cfg), Tuning.match_rules.arena_radius), "versus arena radius unchanged")
