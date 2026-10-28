class_name Beam
extends CombatEntity
## Beam super fired from the caster's hands. Its head grows out at
## `move.travel_speed` up to `move.hitbox_length` of travel, bending toward
## the caster's target by up to `move.beam_homing_deg` per frame until it
## comes within `move.beam_homing_stop_distance` of them (or passes them);
## after that it flies straight, so a late sidestep gets out of the line.
## Only the part already grown can hit: the beam is a polyline (hands ->
## trail points -> head), one capsule hitbox per segment, all sharing the
## beam's hit id so a victim touching several segments is hit once per
## `move.multi_hit_interval`. Pierces (hits every fighter it overlaps) unless
## `move.single_target`. Lasts `move.active` frames (travel + sustain); it
## ends early if the caster leaves the firing move (got hit).

var caster: Fighter
var move: MoveData
var _caster_move_serial: int = 0
## Firing direction (fixed): orients the hands anchor and the entity.
var _dir: Vector3 = Vector3.FORWARD
var _frame: int = 0
## Head of the beam (world) and the direction it is growing in.
var _head: Vector3 = Vector3.ZERO
var _head_dir: Vector3 = Vector3.FORWARD
## Distance the head has travelled (<= move.hitbox_length).
var _travel: float = 0.0
## Still steering toward the target (off for good once it gets close/passes).
var _homing: bool = false
## Homing turned the head since the last trail point.
var _bent: bool = false
## Bend points between the hands and the head (world space, oldest first).
## Bounded: one per `beam_trail_sample_frames` frames of travel at most.
var _trail: PackedVector3Array = PackedVector3Array()
var _visual: BeamVisual


## `aim`: firing direction (ZERO = flat along the caster's facing).
func fire(p_caster: Fighter, p_move: MoveData, caster_move_serial: int, aim: Vector3 = Vector3.ZERO) -> void:
	caster = p_caster
	move = p_move
	_caster_move_serial = caster_move_serial
	_dir = aim
	if _dir.is_zero_approx():
		_dir = -p_caster.global_basis.z
		_dir.y = 0.0
	_dir = _dir.normalized()
	_head_dir = _dir
	_head = _start()
	_travel = 0.0
	_trail = PackedVector3Array()
	_bent = false
	_homing = move.beam_homing_deg > 0.0
	if move.travel_speed <= 0.0:  # instant beam: full length at once
		_travel = move.hitbox_length
		_head = _start() + _dir * move.hitbox_length
		_homing = false
	clear_contacts()
	spawn_init = {"caster": p_caster.sim_id, "move": EntityFactory.move_ref(p_move)}
	_place()
	_build_visual()


func spawn_type() -> StringName:
	return EntityFactory.BEAM


## Factory rebuild: caster and move from spawn_init; load_state does the rest.
func resolve_links(p_director: MatchDirector) -> void:
	caster = p_director.entity_by_id(spawn_init["caster"]) as Fighter
	move = EntityFactory.load_move(spawn_init["move"])
	if _visual == null:
		_build_visual()


func sim_tick(_tick: int) -> void:
	_frame += 1
	if _frame >= move.active or caster.current_move_serial() != _caster_move_serial \
			or caster.current_move() == null:
		sim_dead = true
		return
	_place()
	_grow()


## Advance the head one frame (steer, then move), clamped to the max length.
func _grow() -> void:
	if _travel >= move.hitbox_length:
		return
	if _homing:
		_steer()
	var step := minf(move.travel_speed / Tuning.match_rules.tick_rate, move.hitbox_length - _travel)
	_head += _head_dir * step
	_travel += step
	if _bent and _frame % maxi(move.beam_trail_sample_frames, 1) == 0:
		_trail.append(_head)
		_bent = false


## Turn the head toward the target's beam-height point by at most
## beam_homing_deg; stop homing for good once it is close or behind the head.
func _steer() -> void:
	var t := caster.target
	if t == null or not is_instance_valid(t):
		return
	var to := t.global_position + Vector3.UP * move.hitbox_offset.y - _head
	var dist := to.length()
	if dist <= move.beam_homing_stop_distance or to.dot(_head_dir) <= 0.0:
		_homing = false
		return
	var want := to / dist
	var angle := DetMath.angle_to(_head_dir, want)
	var max_turn := DetMath.deg_to_rad(move.beam_homing_deg)
	if angle <= 0.0:
		return
	if angle <= max_turn:
		_head_dir = want
	else:
		# Rotate toward `want` in the plane they span by max_turn.
		var perp := (want - _head_dir * _head_dir.dot(want)).normalized()
		_head_dir = (_head_dir * DetMath.cos(max_turn) + perp * DetMath.sin(max_turn)).normalized()
	_bent = true


func _start() -> Vector3:
	var right := Vector3.UP.cross(-_dir).normalized()
	var o := move.hitbox_offset
	return caster.global_position + right * o.x + Vector3.UP * o.y + _dir * o.z


func _place() -> void:
	global_position = _start()
	global_basis = DetMath.looking_at(_dir)


## The beam's polyline in world space: hands, bend points, head.
func points() -> PackedVector3Array:
	var pts := PackedVector3Array([_start()])
	pts.append_array(_trail)
	pts.append(_head)
	return pts


func head_position() -> Vector3:
	return _head


## Distance grown so far (m).
func grown_length() -> float:
	return _travel


func get_active_hitboxes() -> Array[Hitbox]:
	var out: Array[Hitbox] = []
	if sim_dead:
		return out
	var hit_id := _frame / maxi(move.multi_hit_interval, 1) if move.multi_hit_interval > 0 else 0
	var pts := points()
	for i in pts.size() - 1:
		var seg := pts[i + 1] - pts[i]
		if seg.length_squared() < 0.000001 and pts.size() > 2:
			continue
		var fwd := seg.normalized() if seg.length_squared() > 0.000001 else _dir
		var flat := Vector3(fwd.x, 0.0, fwd.z)
		if flat.length_squared() < 0.000001:
			flat = Vector3(_dir.x, 0.0, _dir.z)
		var hb := Hitbox.new()
		hb.source = self
		hb.attacker = caster
		hb.move = move
		hb.hit_id = hit_id
		hb.a = pts[i]
		hb.b = pts[i + 1]
		hb.radius = move.hitbox_radius
		hb.origin = caster.global_position
		hb.forward = fwd
		hb.right = Vector3.UP.cross(-flat).normalized()
		hb.is_melee = false
		hb.single_target = move.single_target
		out.append(hb)
	return out


func save_state() -> Dictionary:
	var s := super.save_state()
	s.merge({"frame": _frame, "dir": _dir, "caster_serial": _caster_move_serial, "dead": sim_dead,
		"head": _head, "head_dir": _head_dir, "travel": _travel, "homing": _homing, "bent": _bent,
		"trail": _trail.duplicate()})
	save_contacts(s)
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	_frame = s["frame"]
	_dir = s["dir"]
	load_contacts(s)
	_caster_move_serial = s["caster_serial"]
	sim_dead = s["dead"]
	_head = s["head"]
	_head_dir = s["head_dir"]
	_travel = s["travel"]
	_homing = s["homing"]
	_bent = s["bent"]
	_trail = (s["trail"] as PackedVector3Array).duplicate()


func _build_visual() -> void:
	var c := caster.tint()
	_visual = BeamVisual.new()
	_visual.setup(self, move.hitbox_radius, Color(c.lightened(0.7), 0.85), c.lightened(0.4))
	var smoothed := SmoothedVisual.new()
	smoothed.name = "Visual"
	smoothed.add_child(_visual)
	add_child(smoothed)
