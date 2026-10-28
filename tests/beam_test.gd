extends Node
## Growing, homing beams (Beam): the head travels out at the shot's
## travel_speed, only the grown part hits, homing tracks a slow mover but a
## late sway escapes, the length is clamped, segments don't multiply hits,
## and save/load mid-travel re-simulates identically. Run as a scene:
##   godot --headless res://tests/beam_test.tscn

const B := InputFrame.Btn
const DIST := 12.0

var _failures := 0
var _hits: Array[int] = [0, 0]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_grows_before_hitting, _test_length_clamped, _test_homing_tracks_walker,
		_test_late_sway_escapes, _test_early_sway_tracked, _test_ultimate_grows,
		_test_save_load_mid_travel, _test_determinism,
	]
	for t in tests:
		t.call()
	print("BEAM TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _new_match(distance: float = DIST) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_hits = [0, 0]
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.rng_seed = 7
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
		d.fighters[i].ki = d.fighters[i].ki_max()
		d.fighters[i].event.connect(func(kind: StringName, _data: Dictionary) -> void:
			if kind == &"hit":
				_hits[i] += 1)
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


## Index (relative to the script start) of the next tick to be stepped.
func _next(d: MatchDirector, slot: int) -> int:
	return d.tick + 1 - _src(d, slot).start_tick


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _run_until(d: MatchDirector, cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		d.step()
	return cond.call()


## P1 fires super 2 (forward + SPECIAL; `back` = ultimate); returns the beam
## the tick it spawns.
func _fire(d: MatchDirector, back: bool = false) -> Beam:
	_src(d, 0).stick(0, 2, Vector2(0, -1 if back else 1)).press(0, B.SPECIAL)
	_run_until(d, func() -> bool: return not d.entities.is_empty(), 200)
	return d.entities[0] as Beam if not d.entities.is_empty() else null


func _step_len(b: Beam) -> float:
	return b.move.travel_speed / Tuning.match_rules.tick_rate


func _poly_len(pts: PackedVector3Array) -> float:
	var n := 0.0
	for i in pts.size() - 1:
		n += pts[i].distance_to(pts[i + 1])
	return n


# --- tests ----------------------------------------------------------------------

func _test_grows_before_hitting() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	var beam := _fire(d)
	if not _check(beam != null, "beam spawns"):
		return
	var step := _step_len(beam)
	_check(beam.grown_length() <= step + 0.001, "beam starts short (%.2f m)" % beam.grown_length())
	var frames := 0
	while _hits[1] == 0 and frames < beam.move.active and not beam.sim_dead:
		d.step()
		frames += 1
	var t := p2.tuning
	var gap := DIST - beam.move.hitbox_offset.z - beam.move.hitbox_radius - t.body_radius
	var expected := gap / step
	_check(_hits[1] > 0, "beam reaches the target")
	_check(frames >= floori(expected) - 2, "no hit before the head arrives (%d frames, head needs ~%.1f)" % [frames, expected])
	_check(frames <= ceili(expected) + 3, "hit as soon as the head arrives (%d frames)" % frames)
	_run_until(d, func() -> bool: return beam.sim_dead, 200)
	var max_hits := ceili(float(beam.move.active) / beam.move.multi_hit_interval) + 1
	_check(_hits[1] >= 5 and _hits[1] <= max_hits, "multi-hit, once per interval despite segments (%d hits, max %d)" % [_hits[1], max_hits])


func _test_length_clamped() -> void:
	var d := _new_match()
	var beam := _fire(d)
	if beam == null:
		_check(false, "beam spawns (clamp)")
		return
	# Opponent gone sideways: the beam grows to full length and stops.
	d.fighters[1].global_position = Vector3(15, 0, 0)
	var frames := ceili(beam.move.hitbox_length / _step_len(beam)) + 5
	var longest := 0.0
	for i in frames:
		d.step()
		if beam.sim_dead:
			break
		longest = maxf(longest, _poly_len(beam.points()))
	_check(is_equal_approx(beam.grown_length(), beam.move.hitbox_length), "travel clamped to hitbox_length (%.2f)" % beam.grown_length())
	_check(longest <= beam.move.hitbox_length + 0.01, "polyline never longer than max (%.2f)" % longest)


## P2 strafes at walk speed from the moment the beam fires: homing on hits,
## homing off misses.
func _walker(homing: bool) -> Array:
	var d := _new_match()
	var beam := _fire(d)
	if beam == null:
		return [false, 0]
	if not homing:
		beam.move = beam.move.duplicate()
		beam.move.beam_homing_deg = 0.0
		beam._homing = false
	_src(d, 1).stick(_next(d, 1), _next(d, 1) + 200, Vector2(1, 0))
	_run_until(d, func() -> bool: return beam.sim_dead, 200)
	return [true, _hits[1], beam]


func _test_homing_tracks_walker() -> void:
	var on := _walker(true)
	var off := _walker(false)
	_check(on[0] and on[1] > 0, "homing beam catches a strafing walker (%d hits)" % on[1])
	_check(off[0] and off[1] == 0, "straight beam misses the same walker (%d hits)" % off[1])


## Sway as the head is about to arrive (homing already off): clean escape.
func _test_late_sway_escapes() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	var beam := _fire(d)
	if beam == null:
		_check(false, "beam spawns (late sway)")
		return
	var chest := func() -> Vector3: return p2.global_position + Vector3.UP * beam.move.hitbox_offset.y
	var close := beam.move.hitbox_radius + p2.tuning.body_radius + _step_len(beam) * 4.0
	_check(_run_until(d, func() -> bool: return beam.head_position().distance_to(chest.call()) <= close, 60),
		"head approaches the target")
	_check(not beam._homing, "homing stopped near the target")
	_src(d, 1).flick(_next(d, 1), InputFrame.Dodge.RIGHT)
	_run_until(d, func() -> bool: return beam.sim_dead, 200)
	_check(_hits[1] == 0 and is_equal_approx(p2.health, p2.tuning.max_health),
		"late sway gets out of the line (%d hits, hp %.1f)" % [_hits[1], p2.health])


## Sway the moment it fires: the head bends onto the new spot.
func _test_early_sway_tracked() -> void:
	var d := _new_match()
	var p2 := d.fighters[1]
	var beam := _fire(d)
	if beam == null:
		_check(false, "beam spawns (early sway)")
		return
	_src(d, 1).flick(_next(d, 1), InputFrame.Dodge.RIGHT)
	_run_until(d, func() -> bool: return beam.sim_dead, 200)
	_check(_hits[1] > 0, "early sway gets tracked by the homing head (%d hits)" % _hits[1])
	_check(beam.points().size() > 2, "bent beam keeps trail points (%d points)" % beam.points().size())


func _test_ultimate_grows() -> void:
	var d := _new_match()
	var beam := _fire(d, true)
	if not _check(beam != null and beam.move.id == &"brawler_ultimate_shot", "ultimate beam spawns"):
		return
	_check(beam.grown_length() <= _step_len(beam) + 0.001, "ultimate starts short too")
	_run_until(d, func() -> bool: return beam.sim_dead, 300)
	_check(_hits[1] >= 8, "ultimate still lands its multi-hit (%d hits)" % _hits[1])


func _test_save_load_mid_travel() -> void:
	var d := _new_match()
	var beam := _fire(d)
	if beam == null:
		_check(false, "beam spawns (save/load)")
		return
	_src(d, 1).stick(_next(d, 1), _next(d, 1) + 200, Vector2(1, 0))
	_run(d, 12)
	_check(not beam.sim_dead and beam.grown_length() < beam.move.hitbox_length and beam.points().size() > 2,
		"mid travel with a bent trail (%.2f m, %d points)" % [beam.grown_length(), beam.points().size()])
	var vis := beam.find_child("*", true, false) as SmoothedVisual
	var bv := vis.get_child(0) as BeamVisual if vis != null else null
	if _check(bv != null, "beam has a BeamVisual under its SmoothedVisual"):
		bv.refresh()
		var shown := bv.get_children().filter(func(c: Node) -> bool: return (c as MeshInstance3D).visible).size()
		_check(shown >= beam.points().size() - 1, "mesh follows the bent trail (%d meshes, %d points)" % [shown, beam.points().size()])
	var snap := d.save_state()
	_run(d, 40)
	var first := StateHash.of(d)
	d.load_state(snap)
	_run(d, 40)
	_check(first == StateHash.of(d), "save/load mid travel re-simulates identically")


func _scenario_hash() -> int:
	var d := _new_match()
	_fire(d)
	_src(d, 1).stick(_next(d, 1), _next(d, 1) + 30, Vector2(1, 0)).flick(_next(d, 1) + 10, InputFrame.Dodge.LEFT)
	_run(d, 90)
	return StateHash.of(d)


func _test_determinism() -> void:
	_check(_scenario_hash() == _scenario_hash(), "two identical beam runs hash equal")
