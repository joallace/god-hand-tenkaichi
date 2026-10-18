extends Node
## Headless test for FighterVisual's static poses: grounded poses must rest on
## the floor (y = 0) instead of floating above or sinking into it.
##   godot --headless res://tests/visual_pose_test.tscn

## Max gap (m) allowed between a grounded pose's lowest point and the floor.
const GROUND_TOLERANCE := 0.03
## Max gap (m) between a lying body's torso/limbs and the floor (they touch it).
const LYING_PART_TOLERANCE := 0.05
## Get-up poses whose lowest point must touch the floor.
const GROUNDED: Array[StringName] = [&"knockdown", &"wakeup"]

var _ok := true
var _visual: FighterVisual


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)


func _ready() -> void:
	_visual = FighterVisual.new()
	add_child(_visual)
	for id in GROUNDED:
		_apply(id)
		var low := _lowest(_visual._body)
		print("%s lowest point y = %.3f" % [id, low])
		_check(absf(low) <= GROUND_TOLERANCE, "%s rests on the floor (lowest y %.3f)" % [id, low])
	# Lying down, the torso, legs and arms lie on the floor, not just one limb.
	_apply(&"knockdown")
	for j in [&"torso", &"hip_l", &"hip_r", &"sh_l", &"sh_r"]:
		var low := _lowest(_visual._joints[j], j != &"torso")
		_check(low >= -GROUND_TOLERANCE and low <= LYING_PART_TOLERANCE,
			"knockdown %s on the floor (lowest y %.3f)" % [j, low])
	# Getting up, the planted foot and the kneeling leg both touch the floor.
	_apply(&"wakeup")
	for j in [&"kn_l", &"kn_r"]:
		var low := _lowest(_visual._joints[j])
		_check(absf(low) <= GROUND_TOLERANCE, "wakeup %s on the floor (lowest y %.3f)" % [j, low])
	print("VISUAL POSE TEST %s" % ("PASS" if _ok else "FAIL"))
	get_tree().quit(0 if _ok else 1)


## Snap the visual straight to a named pose (no blending).
func _apply(id: StringName) -> void:
	var pose: Dictionary = FighterVisual.POSES[id]
	var idle: Dictionary = FighterVisual.POSES[&"idle"]
	for j in FighterVisual.JOINTS:
		(_visual._joints[j] as Node3D).rotation_degrees = pose.get(j, idle[j])
	_visual._body.position = pose.get(&"root", idle[&"root"])


## Exact lowest world-space y of every primitive mesh under `node` (only its
## own meshes, not child joints', when `deep` is false).
func _lowest(node: Node, deep := true) -> float:
	var low := INF
	for mi in node.find_children("*", "MeshInstance3D", deep, false):
		var t: Transform3D = (mi as MeshInstance3D).global_transform
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m is CapsuleMesh:
			var half := (m as CapsuleMesh).height * 0.5 - (m as CapsuleMesh).radius
			var a := t * Vector3(0, half, 0)
			var b := t * Vector3(0, -half, 0)
			low = minf(low, minf(a.y, b.y) - (m as CapsuleMesh).radius)
		elif m is SphereMesh:
			low = minf(low, t.origin.y - (m as SphereMesh).radius)
		elif m is BoxMesh:
			var h := (m as BoxMesh).size * 0.5
			for i in 8:
				var c := Vector3(h.x if i & 1 else -h.x, h.y if i & 2 else -h.y, h.z if i & 4 else -h.z)
				low = minf(low, (t * c).y)
	return low
