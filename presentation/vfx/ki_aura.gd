class_name KiAura
extends Node3D
## Ki charge aura around one fighter (presentation only; FighterVisual owns
## it and calls update() every frame). Layers, all on shared materials
## (FxMaterials.Fx) with per-instance tint/power, so a fighter adds no shader:
## - an outer flame shell in the fighter's colour and a smaller, hotter
##   inner one (ki_aura.gdshader on a lathe mesh: wide at the waist, pointed
##   top, flame tongues licking upward),
## - ki motes streaking up around the body (one MultiMesh, animated on the GPU),
## - a swirling ring on the ground.
## It flares up past full size when the charge starts (Tuning.vfx.aura_burst)
## and dies down after it instead of popping in and out. Placed at the
## fighter's feet, scaled with its body.

var _outer: MeshInstance3D
var _inner: MeshInstance3D
var _motes: MultiMeshInstance3D
var _swirl: MeshInstance3D
var _tint := Color.WHITE
## Seconds since the charge started (-1 = not charging).
var _age := -1.0
var _power := 0.0

static var _mesh: ArrayMesh
static var _mote_mesh: MultiMesh


## `tint`: the fighter's colour; `body_scale`: its body scale.
func setup(tint: Color, body_scale: Vector3) -> void:
	var v := Tuning.vfx
	name = "KiAura"
	_tint = tint.lightened(v.aura_lighten)
	scale = body_scale
	var fx_seed := fmod(float(get_instance_id() % 997) * 0.618, 1.0)
	_outer = _shell(fx_seed)
	_inner = _shell(fx_seed + 0.5)
	_inner.scale = Vector3(0.72, 0.8, 0.72)
	_motes = MultiMeshInstance3D.new()
	_motes.multimesh = _shared_motes()
	_motes.material_override = FxMaterials.shared(FxMaterials.Fx.MOTES)
	_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_motes.set_instance_shader_parameter(&"fx_seed", fx_seed)
	add_child(_motes)
	_swirl = FxMaterials.sprite(FxMaterials.Shape.SWIRL, _tint, FxMaterials.Facing.NODE)
	_swirl.basis = Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)) \
			* Basis.from_scale(Vector3.ONE * v.aura_swirl_size)
	_swirl.position.y = v.ground_bounce_height
	_swirl.set_instance_shader_parameter(&"fx_spin", v.aura_swirl_spin)
	_swirl.set_instance_shader_parameter(&"fx_seed", fx_seed)
	_swirl.set_meta(FighterVisual.NO_AFTERIMAGE, true)
	add_child(_swirl)
	_apply()


## Advance by `delta` s; `charging`: ki is filling; `full`: the ki bar is full.
func update(delta: float, charging: bool, full: bool, body_visible: bool) -> void:
	var v := Tuning.vfx
	if charging:
		_age = 0.0 if _age < 0.0 else _age + delta
		var rise := clampf(_age / maxf(v.aura_ramp_in, 0.001), 0.0, 1.0)
		var settle := clampf((_age - v.aura_ramp_in) / maxf(v.aura_ramp_in * 2.0, 0.001), 0.0, 1.0)
		_power = rise * (1.0 + v.aura_burst * (1.0 - settle))
	else:
		_age = -1.0
		_power = maxf(_power - delta / maxf(v.aura_ramp_out, 0.001), 0.0)
	visible = _power > 0.0 and body_visible
	if visible:
		_apply(full)


## Current strength 0..1(+burst) (tests).
func power() -> float:
	return _power


func _apply(full: bool = false) -> void:
	var v := Tuning.vfx
	var c := _tint.lerp(Color.WHITE, 0.3) if full else _tint
	var p := minf(_power, 1.0 + v.aura_burst)
	_outer.set_instance_shader_parameter(&"fx_color", Color(c, v.aura_alpha))
	_outer.set_instance_shader_parameter(&"fx_power", p)
	_inner.set_instance_shader_parameter(&"fx_color", Color(c.lerp(Color.WHITE, 0.3), v.aura_alpha))
	_inner.set_instance_shader_parameter(&"fx_power", p)
	_motes.set_instance_shader_parameter(&"fx_color", Color(c.lerp(Color.WHITE, 0.4), 1.0))
	_motes.set_instance_shader_parameter(&"fx_power", minf(p, 1.0))
	_swirl.set_instance_shader_parameter(&"fx_color", Color(c, minf(p, 1.0) * 0.85))
	_swirl.scale = Vector3.ONE * v.aura_swirl_size * (0.6 + 0.4 * p)


func _shell(fx_seed: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _flame_mesh()
	mi.material_override = FxMaterials.shared(FxMaterials.Fx.AURA)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter(&"fx_seed", fx_seed * 10.0)
	mi.set_meta(FighterVisual.NO_AFTERIMAGE, true)  # aura flames aren't the body
	add_child(mi)
	return mi


## Lathe: UV.x around (0..1, seam duplicated), UV.y = height 0..1; radius
## grows from aura_base_radius to aura_radius at aura_waist, then closes to a
## point at aura_height. Shared by every aura.
static func _flame_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var v := Tuning.vfx
	const AROUND := 24
	const UP := 16
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in UP + 1:
		var h := float(j) / UP
		var r := _radius_at(h)
		var dr := _radius_at(minf(h + 0.01, 1.0)) - _radius_at(maxf(h - 0.01, 0.0))
		var dy := v.aura_height * (minf(h + 0.01, 1.0) - maxf(h - 0.01, 0.0))
		for i in AROUND + 1:
			var a := TAU * i / AROUND
			var radial := Vector3(cos(a), 0.0, sin(a))
			verts.append(radial * r + Vector3.UP * h * v.aura_height)
			normals.append((radial * dy - Vector3.UP * dr).normalized())
			uvs.append(Vector2(float(i) / AROUND, h))
	for j in UP:
		for i in AROUND:
			var a := j * (AROUND + 1) + i
			var b := a + AROUND + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Room for the flame tongues the shader adds.
	_mesh.custom_aabb = AABB(Vector3(-v.aura_radius * 1.5, -0.1, -v.aura_radius * 1.5),
			Vector3(v.aura_radius * 3.0, v.aura_height * 1.5, v.aura_radius * 3.0))
	return _mesh


static func _radius_at(h: float) -> float:
	var v := Tuning.vfx
	if h <= v.aura_waist:
		return lerpf(v.aura_base_radius, v.aura_radius, smoothstep(0.0, 1.0, h / maxf(v.aura_waist, 0.001)))
	var u := (h - v.aura_waist) / maxf(1.0 - v.aura_waist, 0.001)
	return v.aura_radius * sqrt(maxf(1.0 - u * u, 0.0)) * (1.0 - 0.5 * u)


static func _shared_motes() -> MultiMesh:
	if _mote_mesh != null:
		return _mote_mesh
	var v := Tuning.vfx
	_mote_mesh = MultiMesh.new()
	_mote_mesh.transform_format = MultiMesh.TRANSFORM_3D
	_mote_mesh.mesh = FxMaterials.quad()
	_mote_mesh.instance_count = v.aura_mote_count
	for i in v.aura_mote_count:
		_mote_mesh.set_instance_transform(i, Transform3D.IDENTITY)
	# The shader places the motes in a column around the body.
	_mote_mesh.custom_aabb = AABB(Vector3(-1.5, -0.2, -1.5), Vector3(3.0, v.aura_height * 1.3, 3.0))
	return _mote_mesh
