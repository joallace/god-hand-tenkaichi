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
## Standing poses (feet planted) whose lowest point must stay within
## FOOT_TOLERANCE of the floor (no sinking, no floating).
const STANDING: Array[StringName] = [
	&"guard", &"guard_high", &"guard_low", &"counter_guard", &"recoil", &"throw",
	&"throw_windup", &"throw_hold", &"throw_toss", &"taunt", &"uppercut_windup",
	&"hammer", &"hammer_windup", &"smash_left", &"smash_left_windup", &"smash_right",
	&"smash_right_windup", &"duck_kick", &"duck_kick_windup", &"dash_start", &"dash_stop",
	&"charge_end",
]
const FOOT_TOLERANCE := 0.12
## Attack poses that must have a "<pose>_windup" for their startup.
const NEEDS_WINDUP: Array[StringName] = [&"throw", &"uppercut", &"hammer", &"smash_left", &"smash_right",
	&"dive_kick", &"duck_kick"]
const MOVES_DIR := "res://data/moves/"

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
	_test_states_resolve()
	_test_move_poses()
	for id in STANDING:
		_apply(id)
		var low := _lowest(_visual._body)
		print("%s lowest point y = %.3f" % [id, low])
		_check(absf(low) <= FOOT_TOLERANCE, "%s feet on the floor (lowest y %.3f)" % [id, low])
	print("VISUAL POSE TEST %s" % ("PASS" if _ok else "FAIL"))
	get_tree().quit(0 if _ok else 1)


## Every pose Fighter.current_pose() can report outside ATTACK maps to a
## defined pose (no silent fallback to idle).
func _test_states_resolve() -> void:
	var ids: Array[StringName] = [&"knockdown", &"launched"]
	ids.append_array(Fighter.GUARD_POSE_NAMES)
	for d in Fighter.DODGE_NAMES:
		if d != &"none":
			ids.append(d)
	for st in Fighter.STATE_NAMES:
		if st not in [&"attack", &"dodge", &"ko", &"walk", &"throw"]:
			ids.append(st)
	for id in ids:
		_check(FighterVisual.POSES.has(FighterVisual.pose_id_for(id, id, 0, Tuning.fighter)),
			"state pose %s defined" % id)
	_check(FighterVisual.pose_id_for(&"walk", &"walk", 0, Tuning.fighter) == &"idle", "walk -> idle")
	# The thrower holds through the break window, then tosses.
	var hold := FighterVisual.pose_id_for(&"throw", &"throw", 0, Tuning.fighter)
	var toss := FighterVisual.pose_id_for(&"throw", &"throw", Tuning.fighter.throw_break_frames, Tuning.fighter)
	_check(hold == &"throw_hold" and toss == &"throw_toss", "throw state hold -> toss (%s, %s)" % [hold, toss])
	_check(FighterVisual.POSES.has(hold) and FighterVisual.POSES.has(toss), "throw hold/toss poses defined")


## Every move's pose (and the new moves' windups) is defined.
func _test_move_poses() -> void:
	for file in DirAccess.get_files_at(MOVES_DIR):
		if file.get_extension() != "tres":
			continue
		var m := load(MOVES_DIR + file) as MoveData
		if m == null or m.pose == &"":
			continue
		_check(FighterVisual.POSES.has(m.pose), "move %s pose %s defined" % [m.id, m.pose])
	for id in NEEDS_WINDUP:
		_check(FighterVisual.POSES.has(id), "pose %s defined" % id)
		_check(FighterVisual.POSES.has(StringName(String(id) + "_windup")), "pose %s_windup defined" % id)


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
