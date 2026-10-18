class_name InputFrame
extends RefCounted
## One tick of player intent. The ONLY thing gameplay code reads for input.
##
## Device-agnostic and camera-agnostic: `move` is in "fighter space", where
## +Y means "toward the opponent" and +X means "strafe right around the
## opponent". That makes frames identical regardless of where they came from
## (local pad, keyboard, CPU, network), which is what online play needs.
##
## Values are quantized (move to int8-ish range) so frames can be serialized
## compactly and compared exactly for rollback.

enum Btn {
	LIGHT    = 1 << 0,
	HEAVY    = 1 << 1,
	BLAST    = 1 << 2,
	JUMP     = 1 << 3,
	GUARD    = 1 << 4,
	CHARGE   = 1 << 5,
	SPECIAL  = 1 << 6,
	TELEPORT = 1 << 7,
	DASH     = 1 << 8,
	PAUSE    = 1 << 9,
	THROW    = 1 << 10,
	TAUNT    = 1 << 11,
}

## Dodge flick directions (right stick), already in fighter space.
enum Dodge { NONE, FORWARD, BACK, LEFT, RIGHT }

const MOVE_SCALE := 127

## Quantized left stick, each axis in [-127, 127]. Use `move()` for floats.
var move_x: int = 0
var move_y: int = 0
## Bitmask of Button currently held.
var held: int = 0
## Bitmask of Button that went down this tick (edge). Filled by InputSource.
var pressed: int = 0
## Bitmask of Button released this tick (edge).
var released: int = 0
## Dodge flick that fired this tick (edge-triggered; NONE most ticks).
var dodge: Dodge = Dodge.NONE


func move() -> Vector2:
	return Vector2(move_x, move_y) / float(MOVE_SCALE)


func set_move(v: Vector2) -> void:
	v = v.limit_length(1.0)
	move_x = clampi(roundi(v.x * MOVE_SCALE), -MOVE_SCALE, MOVE_SCALE)
	move_y = clampi(roundi(v.y * MOVE_SCALE), -MOVE_SCALE, MOVE_SCALE)


func is_held(b: int) -> bool:
	return held & b != 0


func just_pressed(b: int) -> bool:
	return pressed & b != 0


func just_released(b: int) -> bool:
	return released & b != 0


## Derive edge bits from the previous frame's held mask.
func compute_edges(previous: InputFrame) -> void:
	var prev_held := previous.held if previous else 0
	pressed = held & ~prev_held
	released = prev_held & ~held


func duplicate_frame() -> InputFrame:
	var f := InputFrame.new()
	f.move_x = move_x
	f.move_y = move_y
	f.held = held
	f.pressed = pressed
	f.released = released
	f.dodge = dodge
	return f


func equals(other: InputFrame) -> bool:
	return other != null and move_x == other.move_x and move_y == other.move_y \
		and held == other.held and dodge == other.dodge


## Compact serialization for netcode: [move_x, move_y, held, dodge].
func to_array() -> PackedInt32Array:
	return PackedInt32Array([move_x, move_y, held, dodge])


static func from_array(a: PackedInt32Array) -> InputFrame:
	var f := InputFrame.new()
	f.move_x = a[0]
	f.move_y = a[1]
	f.held = a[2]
	f.dodge = a[3] as Dodge
	return f


static func button_name(b: int) -> String:
	return str(Btn.find_key(b)).capitalize()
