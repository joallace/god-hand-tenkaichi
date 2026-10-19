class_name Beam
extends CombatEntity
## Long capsule hitbox in front of the caster for `move.active` frames,
## re-hitting every `move.multi_hit_interval` frames. Direction is fixed at
## fire time; it ends early if the caster leaves the firing move (got hit).

var caster: Fighter
var move: MoveData
var _caster_move_serial: int = 0
var _dir: Vector3 = Vector3.FORWARD
var _frame: int = 0
var _mesh: MeshInstance3D


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
	_last_contact_id = -1
	spawn_init = {"caster": p_caster.sim_id, "move": EntityFactory.move_ref(p_move)}
	_place()
	_build_visual()


func spawn_type() -> StringName:
	return EntityFactory.BEAM


## Factory rebuild: caster and move from spawn_init; load_state does the rest.
func resolve_links(p_director: MatchDirector) -> void:
	caster = p_director.entity_by_id(spawn_init["caster"]) as Fighter
	move = EntityFactory.load_move(spawn_init["move"])
	if _mesh == null:
		_build_visual()


func sim_tick(_tick: int) -> void:
	_frame += 1
	if _frame >= move.active or caster.current_move_serial() != _caster_move_serial \
			or caster.current_move() == null:
		sim_dead = true
		return
	_place()


func _start() -> Vector3:
	var right := Vector3.UP.cross(-_dir).normalized()
	var o := move.hitbox_offset
	return caster.global_position + right * o.x + Vector3.UP * o.y + _dir * o.z


func _place() -> void:
	global_position = _start()
	global_basis = Basis.looking_at(_dir)


func get_active_hitboxes() -> Array[Hitbox]:
	var out: Array[Hitbox] = []
	if sim_dead:
		return out
	var hb := Hitbox.new()
	hb.source = self
	hb.attacker = caster
	hb.move = move
	hb.hit_id = _frame / maxi(move.multi_hit_interval, 1) if move.multi_hit_interval > 0 else 0
	hb.a = _start()
	hb.b = hb.a + _dir * move.hitbox_length
	hb.radius = move.hitbox_radius
	hb.origin = caster.global_position
	hb.forward = _dir
	hb.right = Vector3.UP.cross(-_dir).normalized()
	hb.is_melee = false
	out.append(hb)
	return out


func save_state() -> Dictionary:
	var s := super.save_state()
	s.merge({"frame": _frame, "dir": _dir, "last_contact": _last_contact_id,
		"caster_serial": _caster_move_serial, "dead": sim_dead})
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	_frame = s["frame"]
	_dir = s["dir"]
	_last_contact_id = s["last_contact"]
	_caster_move_serial = s["caster_serial"]
	sim_dead = s["dead"]


func _build_visual() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = move.hitbox_radius
	cyl.bottom_radius = move.hitbox_radius
	cyl.height = move.hitbox_length
	_mesh.mesh = cyl
	# Cylinder is along Y; lay it along -Z (our forward) and start at origin.
	_mesh.rotation_degrees = Vector3(-90, 0, 0)
	_mesh.position = Vector3(0, 0, -move.hitbox_length * 0.5)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var c := caster.tint()
	mat.albedo_color = Color(c.lightened(0.7), 0.85)
	mat.emission_enabled = true
	mat.emission = c.lightened(0.4)
	mat.emission_energy_multiplier = 4.0
	_mesh.material_override = mat
	add_child(_mesh)
