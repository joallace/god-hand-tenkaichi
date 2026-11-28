class_name KiBlastVisual
extends Node3D
## Presentation only: how a KiBlast looks. A white-hot core ball, a ragged
## flame shell around it, a flickering comet tail streaming behind it and a
## spinning glint, all in the caster's colour on the shared effect materials
## (FxMaterials.Fx), so a blast builds no material. Lives under the blast's
## SmoothedVisual; reads the blast's public velocity() only.

var _blast: KiBlast
var _core: MeshInstance3D
var _shell: MeshInstance3D
var _tail: MeshInstance3D
var _flare: MeshInstance3D
var _tail_length := 1.0

static var _ball: SphereMesh


func setup(blast: KiBlast, radius: float, tint: Color) -> void:
	var v := Tuning.vfx
	name = "KiBlastVisual"
	_blast = blast
	var fx_seed := fmod(float(get_instance_id() % 997) * 0.618, 1.0)
	var dir := _dir()
	var flow := dir * v.energy_flow_speed
	_core = _sphere(FxMaterials.Fx.ENERGY_CORE, radius * v.blast_core_scale, tint, flow, fx_seed)
	_shell = _sphere(FxMaterials.Fx.ENERGY_SHELL, radius * v.blast_shell_scale, tint.lightened(0.15), flow, fx_seed)
	_shell.set_instance_shader_parameter(&"fx_wobble", v.energy_wobble)
	_shell.set_instance_shader_parameter(&"fx_freq", v.energy_freq)
	_tail_length = radius * v.blast_tail_length
	_tail = FxMaterials.sprite(FxMaterials.Shape.TAIL, Color(tint.lightened(0.2), 0.9), FxMaterials.Facing.AXIS)
	_tail.scale = Vector3(radius * v.blast_tail_width, _tail_length, 1.0)
	_tail.set_instance_shader_parameter(&"fx_seed", fx_seed)
	add_child(_tail)
	_flare = FxMaterials.sprite(FxMaterials.Shape.FLARE, Color(tint.lightened(0.5), 0.9))
	_flare.scale = Vector3.ONE * radius * v.blast_flare_scale
	_flare.set_instance_shader_parameter(&"fx_spin", v.blast_flare_spin)
	_flare.set_instance_shader_parameter(&"fx_seed", fx_seed)
	_flare.set_instance_shader_parameter(&"fx_progress", 0.35)
	add_child(_flare)
	_orient()


func _process(_delta: float) -> void:
	_orient()


## Tail behind the ball, along the flight direction.
func _orient() -> void:
	if not is_inside_tree():
		return
	var dir := _dir()
	_tail.set_instance_shader_parameter(&"fx_dir", dir)
	_tail.global_position = global_position - dir * _tail_length * 0.5
	var flow := dir * Tuning.vfx.energy_flow_speed
	_core.set_instance_shader_parameter(&"fx_flow", flow)
	_shell.set_instance_shader_parameter(&"fx_flow", flow)


func _dir() -> Vector3:
	if _blast == null:
		return Vector3.FORWARD
	var vel := _blast.velocity()
	return vel.normalized() if vel.length_squared() > 0.0001 else -_blast.global_basis.z


func _sphere(fx: FxMaterials.Fx, radius: float, tint: Color, flow: Vector3, fx_seed: float) -> MeshInstance3D:
	if _ball == null:
		_ball = SphereMesh.new()
		_ball.radius = 0.5
		_ball.height = 1.0
		_ball.radial_segments = 20
		_ball.rings = 10
	var mi := MeshInstance3D.new()
	mi.mesh = _ball
	mi.scale = Vector3.ONE * radius * 2.0
	mi.material_override = FxMaterials.shared(fx)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter(&"fx_color", tint)
	mi.set_instance_shader_parameter(&"fx_flow", flow)
	mi.set_instance_shader_parameter(&"fx_seed", fx_seed)
	add_child(mi)
	return mi
