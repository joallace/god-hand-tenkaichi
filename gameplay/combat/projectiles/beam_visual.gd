class_name BeamVisual
extends Node3D
## Presentation only: draws a Beam's polyline (hands -> bend points -> head),
## rebuilt every frame from the beam's public points(). Each segment is a
## white-hot core cylinder inside a ragged, streaming flame shell; the head
## is a bigger ball of the same, with spinning glints at the head and at the
## hands. All on the shared effect materials (FxMaterials.Fx; per-instance
## tint and flow), so a beam builds no material. Lives under the beam's
## SmoothedVisual, so points are placed relative to the beam's sim transform
## and ride the smoothed one. Never writes beam state.

var _beam: Beam
var _radius: float = 0.5
var _tint := Color.WHITE
var _seed := 0.0
var _cores: Array[MeshInstance3D] = []
var _shells: Array[MeshInstance3D] = []
var _head_core: MeshInstance3D
var _head_shell: MeshInstance3D
var _head_flare: MeshInstance3D
var _hand_flare: MeshInstance3D

static var _cyl: CylinderMesh
static var _tube: CylinderMesh
static var _ball: SphereMesh


func setup(beam: Beam, radius: float, tint: Color) -> void:
	var v := Tuning.vfx
	_beam = beam
	_radius = radius
	_tint = tint
	_seed = float(get_instance_id() % 97) / 97.0
	if _cyl == null:
		_cyl = CylinderMesh.new()
		_cyl.top_radius = 0.5
		_cyl.bottom_radius = 0.5
		_cyl.height = 1.0
		_cyl.radial_segments = 16
		_cyl.rings = 1
		_tube = _cyl.duplicate() as CylinderMesh
		_tube.cap_top = false
		_tube.cap_bottom = false
		_tube.rings = 4
		_ball = SphereMesh.new()
		_ball.radius = 0.5
		_ball.height = 1.0
		_ball.radial_segments = 20
		_ball.rings = 10
	var head := radius * v.beam_head_scale * 2.0
	_head_core = _part(_ball, FxMaterials.Fx.ENERGY_CORE)
	_head_core.scale = Vector3.ONE * head * v.beam_core_scale
	_head_shell = _part(_ball, FxMaterials.Fx.ENERGY_SHELL)
	_head_shell.scale = Vector3.ONE * head * v.beam_shell_scale
	_head_flare = _flare(radius * v.beam_flare_scale)
	_hand_flare = _flare(radius * v.beam_flare_scale * 0.8)


func _process(_delta: float) -> void:
	refresh()


## Lay the meshes along the beam's current points (public for tests).
func refresh() -> void:
	if _beam == null or not _beam.is_inside_tree():
		return
	var v := Tuning.vfx
	var to_local := _beam.global_transform.affine_inverse()
	var pts := _beam.points()
	var n := pts.size() - 1
	while _cores.size() < n:
		_cores.append(_part(_cyl, FxMaterials.Fx.ENERGY_CORE))
		_shells.append(_part(_tube, FxMaterials.Fx.ENERGY_SHELL))
	var last_dir := -_beam.global_basis.z
	for i in _cores.size():
		var core := _cores[i]
		var shell := _shells[i]
		var a := to_local * pts[mini(i, n)]
		var b := to_local * pts[mini(i + 1, n)]
		var seg := b - a
		var length := seg.length()
		var on := i < n and length > 0.0001
		core.visible = on
		shell.visible = on
		if not on:
			continue
		# Cylinder runs along local Y: Y = segment, X/Z any perpendicular pair.
		var y := seg / length
		var x := y.cross(Vector3.UP if absf(y.y) < 0.99 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		var d_core := _radius * 2.0 * v.beam_core_scale
		var d_shell := _radius * 2.0 * v.beam_shell_scale
		core.transform = _seg_transform(x * d_core, y * length, z * d_core, (a + b) * 0.5)
		shell.transform = _seg_transform(x * d_shell, y * length, z * d_shell, (a + b) * 0.5)
		var world_dir := (pts[i + 1] - pts[i]).normalized()
		last_dir = world_dir
		var flow := world_dir * v.beam_flow_speed
		core.set_instance_shader_parameter(&"fx_flow", flow)
		shell.set_instance_shader_parameter(&"fx_flow", flow)
	var head := to_local * pts[pts.size() - 1]
	_head_core.position = head
	_head_shell.position = head
	_head_flare.position = head
	_hand_flare.position = to_local * pts[0]
	var head_flow := last_dir * v.beam_flow_speed
	_head_core.set_instance_shader_parameter(&"fx_flow", head_flow)
	_head_shell.set_instance_shader_parameter(&"fx_flow", head_flow)


func _seg_transform(x: Vector3, y: Vector3, z: Vector3, origin: Vector3) -> Transform3D:
	var basis := Basis.IDENTITY
	basis.x = x
	basis.y = y
	basis.z = z
	return Transform3D(basis, origin)


func _part(mesh: Mesh, fx: FxMaterials.Fx) -> MeshInstance3D:
	var v := Tuning.vfx
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = FxMaterials.shared(fx)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shell := fx == FxMaterials.Fx.ENERGY_SHELL
	mi.set_instance_shader_parameter(&"fx_color", _tint.lightened(0.15) if shell else _tint)
	mi.set_instance_shader_parameter(&"fx_seed", _seed)
	mi.set_instance_shader_parameter(&"fx_wobble", _radius * v.beam_wobble)
	mi.set_instance_shader_parameter(&"fx_freq", v.energy_freq / maxf(_radius * 2.0, 0.25))
	add_child(mi)
	return mi


func _flare(size: float) -> MeshInstance3D:
	var v := Tuning.vfx
	var mi := FxMaterials.sprite(FxMaterials.Shape.FLARE, Color(_tint.lightened(0.5), 0.95))
	mi.scale = Vector3.ONE * size
	mi.set_instance_shader_parameter(&"fx_spin", v.beam_flare_spin)
	mi.set_instance_shader_parameter(&"fx_seed", _seed)
	mi.set_instance_shader_parameter(&"fx_progress", 0.2)
	add_child(mi)
	return mi
