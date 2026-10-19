class_name DetMath
## Deterministic math for sim code (SPEC_ONLINE.md §6). Godot's `sin`, `cos`,
## `atan2`, `angle_to`, `rotated`, `Basis(axis, angle)` etc. call the
## platform's libm, whose transcendentals differ in the last bits between
## Linux and Windows; a rollback peer would drift. Everything here is built
## only from IEEE + − × ÷, sqrt and floor (bit-identical on x86-64 SSE2), so
## the same inputs give the same bits on every OS. View code may use any math.
##
## Accuracy (float64, measured by tests/det_math_test against the built-ins):
##   - sin / cos: Cody-Waite range reduction to [-π/4, π/4] (exact for
##     |x| < ~1.6e6, degrades beyond) and degree-13/14 minimax polynomials:
##     max abs error 1.2e-16 (≤ 1 ulp) measured over |x| <= 1e6.
##   - atan / atan2: reduction to |t| <= 7/16 around 4 breakpoints and a
##     degree-23 minimax polynomial: max abs error 4.5e-16. atan2 is exact on
##     the axes (0, ±π/2, π); atan2(0, 0) = 0, atan2(±0, x < 0) = π.
##   - angle_to / rotate_y / yaw_basis inherit those (≈1e-16 before the
##     float32 rounding of Vector3 / Basis components).
## The polynomial coefficients are the classic public-domain fdlibm minimax
## sets; changing any constant changes results bitwise (det_math_test pins
## a few bit patterns on purpose).

const PI_VAL := PI
const HALF_PI := PI / 2.0
const DEG_PER_RAD := 180.0 / PI
const RAD_PER_DEG := PI / 180.0

# The coefficients are given as IEEE-754 bit patterns, not decimal literals:
# Godot's float literal parser is not correctly rounded (e.g. it reads
# 1.57079632673412561417 one ulp high), and one ulp in PIO2_HI alone costs
# ~1e-12 at |x| = 1e4. static vars because a const can't call _bits().

# Range reduction: n = round(x * 2/π), r = x - n·π/2 with π/2 split in two so
# n * PIO2_HI is exact for |n| < 2^20 (PIO2_HI has 33 significant bits).
static var TWO_OVER_PI := _bits(0x3FE45F306DC9C883)
static var PIO2_HI := _bits(0x3FF921FB54400000)
static var PIO2_LO := _bits(0x3DD0B4611A626331)

# sin(r) ≈ r + r³·(S1 + r²·(S2 + …)) on [-π/4, π/4].
static var S1 := -_bits(0x3FC5555555555549)
static var S2 := _bits(0x3F8111111110F8A6)
static var S3 := -_bits(0x3F2A01A019C161D5)
static var S4 := _bits(0x3EC71DE357B1FE7D)
static var S5 := -_bits(0x3E5AE5E68A2B9CEB)
static var S6 := _bits(0x3DE5D93A5ACFD57C)
# cos(r) ≈ 1 - r²/2 + r⁴·(C1 + r²·(C2 + …)) on [-π/4, π/4].
static var C1 := _bits(0x3FA555555555554C)
static var C2 := -_bits(0x3F56C16C16C15177)
static var C3 := _bits(0x3EFA01A019CB1590)
static var C4 := -_bits(0x3E927E4F809C52AD)
static var C5 := _bits(0x3E21EE9EBDB4B1C4)
static var C6 := -_bits(0x3DA8FAE9BE8838D4)

# atan breakpoints (|x| below each picks a reduction) and the atan of each
# reduction centre (0.5, 1, 1.5, ∞) split hi + lo.
const ATAN_BREAK: Array[float] = [7.0 / 16.0, 11.0 / 16.0, 19.0 / 16.0, 39.0 / 16.0]
static var ATAN_HI := PackedFloat64Array([_bits(0x3FDDAC670561BB4F), _bits(0x3FE921FB54442D18),
	_bits(0x3FEF730BD281F69B), _bits(0x3FF921FB54442D18)])
static var ATAN_LO := PackedFloat64Array([_bits(0x3C7A2B7F222F65E2), _bits(0x3C81A62633145C07),
	_bits(0x3C7007887AF0CBBD), _bits(0x3C91A62633145C07)])
# atan(t) ≈ t - t·(t²·(AT0 + t⁴·(AT2 + …)) + t⁴·(AT1 + t⁴·(AT3 + …))).
static var AT0 := _bits(0x3FD555555555550D)
static var AT1 := -_bits(0x3FC999999998EBC4)
static var AT2 := _bits(0x3FC24924920083FF)
static var AT3 := -_bits(0x3FBC71C6FE231671)
static var AT4 := _bits(0x3FB745CDC54C206E)
static var AT5 := -_bits(0x3FB3B0F2AF749A6D)
static var AT6 := _bits(0x3FB10D66A0D03D51)
static var AT7 := -_bits(0x3FADDE2D52DEFD9A)
static var AT8 := _bits(0x3FA97B4B24760DEB)
static var AT9 := -_bits(0x3FA2B4442C6A6C2F)
static var AT10 := _bits(0x3F90AD3AE322DA11)


static func deg_to_rad(deg: float) -> float:
	return deg * RAD_PER_DEG


static func rad_to_deg(rad: float) -> float:
	return rad * DEG_PER_RAD


static func sin(x: float) -> float:
	var n := floorf(x * TWO_OVER_PI + 0.5)
	var r := (x - n * PIO2_HI) - n * PIO2_LO
	match int(n) & 3:
		0: return _k_sin(r)
		1: return _k_cos(r)
		2: return -_k_sin(r)
		_: return -_k_cos(r)


static func cos(x: float) -> float:
	var n := floorf(x * TWO_OVER_PI + 0.5)
	var r := (x - n * PIO2_HI) - n * PIO2_LO
	match int(n) & 3:
		0: return _k_cos(r)
		1: return -_k_sin(r)
		2: return -_k_cos(r)
		_: return _k_sin(r)


static func atan(x: float) -> float:
	var ax := absf(x)
	var id := -1
	if ax >= ATAN_BREAK[3]:
		id = 3
		ax = -1.0 / ax
	elif ax >= ATAN_BREAK[2]:
		id = 2
		ax = (ax - 1.5) / (1.0 + 1.5 * ax)
	elif ax >= ATAN_BREAK[1]:
		id = 1
		ax = (ax - 1.0) / (ax + 1.0)
	elif ax >= ATAN_BREAK[0]:
		id = 0
		ax = (2.0 * ax - 1.0) / (2.0 + ax)
	var z := ax * ax
	var w := z * z
	var s1 := z * (AT0 + w * (AT2 + w * (AT4 + w * (AT6 + w * (AT8 + w * AT10)))))
	var s2 := w * (AT1 + w * (AT3 + w * (AT5 + w * (AT7 + w * AT9))))
	var res: float
	if id < 0:
		res = ax - ax * (s1 + s2)
	else:
		res = ATAN_HI[id] - ((ax * (s1 + s2) - ATAN_LO[id]) - ax)
	return -res if x < 0.0 else res


## Angle of (x, y) from +X in (-π, π], like the built-in atan2.
static func atan2(y: float, x: float) -> float:
	var ax := absf(x)
	var ay := absf(y)
	if ax == 0.0 and ay == 0.0:
		return 0.0
	var a: float
	if ay <= ax:
		a = DetMath.atan(ay / ax)
	else:
		a = HALF_PI - DetMath.atan(ax / ay)
	if x < 0.0:
		a = PI_VAL - a
	return -a if y < 0.0 else a


## Unsigned angle between two 3D vectors in [0, π] (Vector3.angle_to).
static func angle_to(a: Vector3, b: Vector3) -> float:
	return DetMath.atan2(a.cross(b).length(), a.dot(b))


## Signed angle from `a` to `b` in (-π, π] (Vector2.angle_to).
static func angle_to_2d(a: Vector2, b: Vector2) -> float:
	return DetMath.atan2(a.cross(b), a.dot(b))


## `v` rotated by `angle` radians about +Y (v.rotated(Vector3.UP, angle)).
static func rotate_y(v: Vector3, angle: float) -> Vector3:
	var c := DetMath.cos(angle)
	var s := DetMath.sin(angle)
	return Vector3(c * v.x + s * v.z, v.y, c * v.z - s * v.x)


## Rotation by `yaw` about +Y (Basis(Vector3.UP, yaw)), built from columns.
## Forward (-Z column negated) = (-sin, 0, -cos).
static func yaw_basis(yaw: float) -> Basis:
	var c := DetMath.cos(yaw)
	var s := DetMath.sin(yaw)
	return Basis(Vector3(c, 0.0, -s), Vector3.UP, Vector3(s, 0.0, c))


## Yaw whose forward (-Z) points along `dir` on the XZ plane (0 = -Z).
static func yaw_of(dir: Vector3) -> float:
	return DetMath.atan2(-dir.x, -dir.z)


## Basis.looking_at(target, up): -Z toward `target`. Already arithmetic-only
## (cross products + normalize); kept here so sim code needn't call it.
static func looking_at(target: Vector3, up := Vector3.UP) -> Basis:
	var z := -target.normalized()
	var x := up.cross(z).normalized()
	var y := z.cross(x)
	return Basis(x, y, z)


static func _k_sin(r: float) -> float:
	var z := r * r
	var v := z * r
	return r + v * (S1 + z * (S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))))


static func _k_cos(r: float) -> float:
	var z := r * r
	var hz := 0.5 * z
	var w := 1.0 - hz
	var p := z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
	return w + (((1.0 - w) - hz) + z * p)


## The float64 whose IEEE-754 bit pattern is `b`.
static func _bits(b: int) -> float:
	return PackedInt64Array([b]).to_byte_array().decode_double(0)
