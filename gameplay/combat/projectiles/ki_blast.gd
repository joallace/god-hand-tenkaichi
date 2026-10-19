class_name KiBlast
extends CombatEntity
## Straight-flying ki ball. Hit payload = a MoveData (radius, damage, speed,
## lifetime). Dies on hit or block; passes through dodges.

var caster: Fighter
var move: MoveData
var _vel: Vector3 = Vector3.ZERO
var _frame: int = 0
var _mesh: MeshInstance3D


func launch(p_caster: Fighter, p_move: MoveData, from: Vector3, toward: Vector3) -> void:
	caster = p_caster
	move = p_move
	global_position = from
	var dir := toward - from
	if dir.length_squared() < 0.0001:
		dir = -p_caster.global_basis.z
	_vel = dir.normalized() * move.travel_speed
	_last_contact_id = -1
	spawn_init = {"caster": p_caster.sim_id, "move": EntityFactory.move_ref(p_move)}
	_build_visual()


func spawn_type() -> StringName:
	return EntityFactory.KI_BLAST


## Factory rebuild: caster and move from spawn_init; load_state does the rest.
func resolve_links(p_director: MatchDirector) -> void:
	caster = p_director.entity_by_id(spawn_init["caster"]) as Fighter
	move = EntityFactory.load_move(spawn_init["move"])
	if _mesh == null:
		_build_visual()


func sim_tick(_tick: int) -> void:
	_frame += 1
	global_position += _vel / Tuning.match_rules.tick_rate
	var limit := Tuning.match_rules.arena_radius * 1.5
	if _frame >= move.lifetime_frames or Vector2(global_position.x, global_position.z).length() > limit \
			or global_position.y < 0.0:
		sim_dead = true


func get_active_hitboxes() -> Array[Hitbox]:
	var out: Array[Hitbox] = []
	if sim_dead:
		return out
	var hb := Hitbox.new()
	hb.source = self
	hb.attacker = caster
	hb.move = move
	hb.hit_id = 1
	hb.a = global_position
	hb.b = global_position
	hb.radius = move.hitbox_radius
	hb.origin = global_position
	hb.forward = _vel.normalized()
	hb.right = Vector3.UP.cross(hb.forward).normalized() * -1.0
	hb.is_melee = false
	out.append(hb)
	return out


func on_hitbox_contact(hb: Hitbox, victim: Fighter, outcome: Contact) -> void:
	super.on_hitbox_contact(hb, victim, outcome)
	if outcome == Contact.HIT or outcome == Contact.BLOCKED:
		sim_dead = true


func save_state() -> Dictionary:
	var s := super.save_state()
	s.merge({"vel": _vel, "frame": _frame, "last_contact": _last_contact_id, "dead": sim_dead})
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	_vel = s["vel"]
	_frame = s["frame"]
	_last_contact_id = s["last_contact"]
	sim_dead = s["dead"]


func _build_visual() -> void:
	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = move.hitbox_radius
	sphere.height = move.hitbox_radius * 2.0
	_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var c := caster.tint() if caster else Color.WHITE
	mat.albedo_color = c.lightened(0.6)
	mat.emission_enabled = true
	mat.emission = c.lightened(0.3)
	mat.emission_energy_multiplier = 3.0
	_mesh.material_override = mat
	add_child(_mesh)
