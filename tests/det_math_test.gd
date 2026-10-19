extends Node
## Headless test for DetMath (SPEC_ONLINE.md §6 rule 1):
##   godot --headless res://tests/det_math_test.tscn
## Checks DetMath against Godot's built-ins over sweeps (large/negative
## angles, every atan2 quadrant and axis), and pins the exact bit patterns of
## a few results: those must never change, on any OS, or online peers would
## desync. If an intended implementation change moves them, update GOLDEN.

## Abs error bounds vs the float64 built-ins.
const TOL_TRIG := 1e-15
const TOL_TRIG_HUGE := 1e-14  # |x| up to 1e6 (range reduction exact to ~1.6e6)
const TOL_ATAN := 1e-15
## Godot's Vector3 / Basis math runs in float32.
const TOL_F32 := 1e-5
const SWEEP_STEPS := 20000
const RANDOM_CASES := 2000
const SEED := 12345

## [function, input(s), little-endian float64 hex of the result]. Inputs are
## dyadic (exact in binary) so the literal parser can't move them; the scalar
## results equal glibc's correctly rounded ones.
const GOLDEN := [
	["sin", [0.5], "f0054b74e8aede3f"],
	["sin", [-123.4375], "72033c5e9a5ee93f"],
	["cos", [2.0], "0572535726a2dabf"],
	["cos", [1000.0], "bbf1936702ffe13f"],
	["atan2", [0.3125, -0.6875], "b0bd6fa73fb80540"],
	["atan2", [-2.0, 1.25], "bead547ef531f0bf"],
	["atan", [3.0], "60857a6b17fcf33f"],
	["angle_to", [Vector3(1, 0, 0.5), Vector3(-0.25, 0, -1)], "041661ea413c0240"],
]

var _fails := 0


func _ready() -> void:
	_test_sin_cos()
	_test_atan2()
	_test_vectors()
	_test_golden()
	print("DET_MATH %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func _test_sin_cos() -> void:
	var worst := 0.0
	var at := 0.0
	# Dense over a few turns either side, then sparse out to ±1e4.
	for i in SWEEP_STEPS + 1:
		var x := lerpf(-4.0 * TAU, 4.0 * TAU, float(i) / SWEEP_STEPS)
		for v in [x, x * 397.0 + 0.1234]:
			var e := maxf(absf(DetMath.sin(v) - sin(v)), absf(DetMath.cos(v) - cos(v)))
			if e > worst:
				worst = e
				at = v
	print("  sin/cos max abs error %s at %f" % [_e(worst), at])
	check(worst <= TOL_TRIG, "sin/cos match built-ins over ±1e4 (%s)" % _e(worst))

	var huge := 0.0
	for x in [1e5, -1e5 - 0.3, 5e5 + 0.77, -1e6, 1e6 - 1.0]:
		huge = maxf(huge, maxf(absf(DetMath.sin(x) - sin(x)), absf(DetMath.cos(x) - cos(x))))
	check(huge <= TOL_TRIG_HUGE, "sin/cos within tolerance up to 1e6 (%s)" % _e(huge))

	check(DetMath.sin(0.0) == 0.0 and DetMath.cos(0.0) == 1.0, "sin(0) = 0, cos(0) = 1 exactly")
	check(absf(DetMath.sin(PI)) < 1e-15 and DetMath.cos(PI) == -1.0, "sin(π) ≈ 0, cos(π) = -1")
	check(DetMath.sin(PI / 2) == 1.0 and DetMath.sin(-PI / 2) == -1.0, "sin(±π/2) = ±1")
	check(is_equal_approx(DetMath.deg_to_rad(90.0), PI / 2) and is_equal_approx(DetMath.rad_to_deg(PI), 180.0),
		"deg/rad conversions")


func _test_atan2() -> void:
	var worst := 0.0
	var vals := [-1e6, -3.0, -1.0, -0.5, -1e-3, -1e-12, 0.0, 1e-12, 1e-3, 0.5, 1.0, 3.0, 1e6]
	for y in vals:
		for x in vals:
			worst = maxf(worst, absf(DetMath.atan2(y, x) - atan2(y, x)))
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in RANDOM_CASES:
		var a := rng.randf_range(-TAU, TAU)
		var r := rng.randf_range(1e-4, 100.0)
		var y := r * sin(a)
		var x := r * cos(a)
		worst = maxf(worst, absf(DetMath.atan2(y, x) - atan2(y, x)))
		var t := rng.randf_range(-50.0, 50.0)
		worst = maxf(worst, absf(DetMath.atan(t) - atan(t)))
	print("  atan/atan2 max abs error %s" % _e(worst))
	check(worst <= TOL_ATAN, "atan/atan2 match built-ins, all quadrants (%s)" % _e(worst))
	check(DetMath.atan2(0.0, 1.0) == 0.0 and DetMath.atan2(0.0, -1.0) == PI, "atan2 on the X axis exact")
	check(DetMath.atan2(1.0, 0.0) == PI / 2 and DetMath.atan2(-1.0, 0.0) == -PI / 2, "atan2 on the Y axis exact")
	check(DetMath.atan2(0.0, 0.0) == 0.0, "atan2(0, 0) = 0")
	check(DetMath.atan2(1.0, 1.0) == PI / 4, "atan2(1, 1) = π/4")


func _test_vectors() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var e_ang := 0.0
	var e_ang2 := 0.0
	var e_rot := 0.0
	var e_basis := 0.0
	var e_look := 0.0
	var e_yaw := 0.0
	for i in RANDOM_CASES:
		var a := Vector3(rng.randf_range(-5, 5), rng.randf_range(-5, 5), rng.randf_range(-5, 5))
		var b := Vector3(rng.randf_range(-5, 5), rng.randf_range(-5, 5), rng.randf_range(-5, 5))
		var ang := rng.randf_range(-20.0, 20.0)
		e_ang = maxf(e_ang, absf(DetMath.angle_to(a, b) - a.angle_to(b)))
		var a2 := Vector2(a.x, a.z)
		var b2 := Vector2(b.x, b.z)
		e_ang2 = maxf(e_ang2, absf(DetMath.angle_to_2d(a2, b2) - a2.angle_to(b2)))
		e_rot = maxf(e_rot, (DetMath.rotate_y(a, ang) - a.rotated(Vector3.UP, ang)).length())
		var db := DetMath.yaw_basis(ang)
		var gb := Basis(Vector3.UP, ang)
		for c in 3:
			e_basis = maxf(e_basis, (db[c] - gb[c]).length())
		var flat := Vector3(a.x, 0.0, a.z)
		if flat.length() > 0.01:
			var dl := DetMath.looking_at(a)
			var gl := Basis.looking_at(a)
			for c in 3:
				e_look = maxf(e_look, (dl[c] - gl[c]).length())
			var fwd := -DetMath.yaw_basis(DetMath.yaw_of(flat)).z
			e_yaw = maxf(e_yaw, (fwd - flat.normalized()).length())
	print("  angle_to %s  angle_to_2d %s  rotate_y %s  yaw_basis %s  looking_at %s  yaw_of %s"
		% [_e(e_ang), _e(e_ang2), _e(e_rot), _e(e_basis), _e(e_look), _e(e_yaw)])
	check(e_ang <= TOL_F32, "angle_to matches Vector3.angle_to")
	check(e_ang2 <= TOL_F32, "angle_to_2d matches Vector2.angle_to (signed)")
	check(e_rot <= TOL_F32, "rotate_y matches rotated(UP, angle)")
	check(e_basis <= TOL_F32, "yaw_basis matches Basis(UP, yaw)")
	check(e_look <= TOL_F32, "looking_at matches Basis.looking_at")
	check(e_yaw <= TOL_F32, "yaw_basis(yaw_of(dir)) faces dir")
	var fwd0 := -DetMath.yaw_basis(0.0).z
	check(fwd0 == Vector3.FORWARD, "yaw 0 faces -Z exactly")


func _test_golden() -> void:
	for g in GOLDEN:
		var args: Array = g[1]
		var v := _call(g[0], args)
		var hex := PackedFloat64Array([v]).to_byte_array().hex_encode()
		check(hex == g[2], "%s%s bits %s (want %s)" % [g[0], str(args), hex, g[2]])


func _call(fn: String, a: Array) -> float:
	match fn:
		"sin": return DetMath.sin(a[0])
		"cos": return DetMath.cos(a[0])
		"atan": return DetMath.atan(a[0])
		"atan2": return DetMath.atan2(a[0], a[1])
		"angle_to": return DetMath.angle_to(a[0], a[1])
	push_error("unknown DetMath function " + fn)
	return NAN


func _e(x: float) -> String:
	return String.num_scientific(x)
