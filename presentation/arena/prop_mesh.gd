class_name PropMesh
extends RefCounted
## Builds one vertex-coloured ArrayMesh out of boxes, tubes and quads, so a
## prop is a single draw call (and a MultiMesh instance) instead of a node per
## part: see docs/web_performance.md. All drawn with material().

var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()


## Corners counter-clockwise seen from the outside.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	var n := (b - a).cross(d - a).normalized()
	_tri(a, c, b, n, n, n, color)
	_tri(a, d, c, n, n, n, color)


## Corners counter-clockwise seen from the outside.
func tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	_tri(a, c, b, n, n, n, color)


## Seen from both sides (a leaf).
func two_sided_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	quad(a, b, c, d, color)
	quad(d, c, b, a, color)


## A size-sized box centred on xf.origin.
func box(xf: Transform3D, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var p: Array[Vector3] = []
	for i in 8:
		p.append(xf * Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1)))
	quad(p[4], p[5], p[7], p[6], color)  # +z
	quad(p[1], p[0], p[2], p[3], color)  # -z
	quad(p[5], p[1], p[3], p[7], color)  # +x
	quad(p[0], p[4], p[6], p[2], color)  # -x
	quad(p[6], p[7], p[3], p[2], color)  # +y
	quad(p[0], p[1], p[5], p[4], color)  # -y


## Axis-aligned box from its centre.
func block(center: Vector3, size: Vector3, color: Color) -> void:
	box(Transform3D(Basis.IDENTITY, center), size, color)


## Smooth tube through `points`, radii[i] thick at each one (a radius of 0
## closes that end).
func tube(points: PackedVector3Array, radii: PackedFloat32Array, sides: int, color: Color) -> void:
	var t := (points[points.size() - 1] - points[0]).normalized()
	var rings: Array[PackedVector3Array] = []
	var ring_normals: Array[PackedVector3Array] = []
	for i in points.size():
		var along := (points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]).normalized()
		if along.is_zero_approx():
			along = t
		# Per ring: a closed loop has no single axis to build a frame from.
		var up := Vector3.FORWARD if absf(along.y) > 0.9 else Vector3.UP
		var u := up.cross(along).normalized()
		var v := along.cross(u).normalized()
		var ring := PackedVector3Array()
		var normals := PackedVector3Array()
		for s in sides:
			var a := TAU * s / sides
			var n := u * cos(a) + v * sin(a)
			ring.append(points[i] + n * radii[i])
			normals.append(n)
		rings.append(ring)
		ring_normals.append(normals)
	for i in points.size() - 1:
		for s in sides:
			var e := (s + 1) % sides
			var a := rings[i][s]
			var b := rings[i][e]
			var c := rings[i + 1][e]
			var d := rings[i + 1][s]
			var na := ring_normals[i][s]
			var nb := ring_normals[i][e]
			var nc := ring_normals[i + 1][e]
			var nd := ring_normals[i + 1][s]
			_tri(a, c, b, na, nc, nb, color)
			_tri(a, d, c, na, nd, nc, color)


## Closed cylinder or cone between two points.
func rod(from: Vector3, to: Vector3, radius_from: float, radius_to: float, sides: int, color: Color) -> void:
	tube(PackedVector3Array([from, from, to, to]), PackedFloat32Array([0.0, radius_from, radius_to, 0.0]), sides, color)


func commit() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The one material every PropMesh is drawn with: vertex colour times the
## MultiMesh instance colour.
static func material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.85
	return m


## Godot's front faces are clockwise.
func _tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, color: Color) -> void:
	_verts.append(a)
	_verts.append(b)
	_verts.append(c)
	_normals.append(na)
	_normals.append(nb)
	_normals.append(nc)
	for i in 3:
		_colors.append(color)
