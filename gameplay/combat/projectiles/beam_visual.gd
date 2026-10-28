class_name BeamVisual
extends Node3D
## Presentation only: draws a Beam's polyline (hands -> bend points -> head)
## as one cylinder per segment plus a glowing head ball, rebuilt every frame
## from the beam's public points(). Lives under the beam's SmoothedVisual, so
## points are placed relative to the beam's sim transform and ride the
## smoothed one. Never writes beam state.

var _beam: Beam
var _radius: float = 0.5
var _cyl: CylinderMesh
var _mat: StandardMaterial3D
var _segments: Array[MeshInstance3D] = []
var _head: MeshInstance3D


func setup(beam: Beam, radius: float, color: Color, glow: Color) -> void:
	_beam = beam
	_radius = radius
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = color
	_mat.emission_enabled = true
	_mat.emission = glow
	_mat.emission_energy_multiplier = Tuning.vfx.beam_glow_energy
	_cyl = CylinderMesh.new()
	_cyl.top_radius = radius
	_cyl.bottom_radius = radius
	_cyl.height = 1.0  # scaled per segment
	_head = MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = radius * Tuning.vfx.beam_head_scale
	ball.height = ball.radius * 2.0
	_head.mesh = ball
	_head.material_override = _mat
	add_child(_head)


func _process(_delta: float) -> void:
	refresh()


## Lay the meshes along the beam's current points (public for tests).
func refresh() -> void:
	if _beam == null or not _beam.is_inside_tree():
		return
	var to_local := _beam.global_transform.affine_inverse()
	var pts := _beam.points()
	var n := pts.size() - 1
	while _segments.size() < n:
		var mi := MeshInstance3D.new()
		mi.mesh = _cyl
		mi.material_override = _mat
		add_child(mi)
		_segments.append(mi)
	for i in _segments.size():
		var mi := _segments[i]
		if i >= n:
			mi.visible = false
			continue
		var a := to_local * pts[i]
		var b := to_local * pts[i + 1]
		var seg := b - a
		var length := seg.length()
		mi.visible = length > 0.0001
		if not mi.visible:
			continue
		# Cylinder runs along local Y: Y = segment, X/Z any perpendicular pair.
		var y := seg / length
		var x := y.cross(Vector3.UP if absf(y.y) < 0.99 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		var basis := Basis.IDENTITY
		basis.x = x
		basis.y = y * length
		basis.z = z
		mi.transform = Transform3D(basis, (a + b) * 0.5)
	_head.position = to_local * pts[pts.size() - 1]
