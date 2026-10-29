class_name Hitbox
extends RefCounted
## A live hitbox for one tick, built by its source (Fighter, KiBlast, Beam)
## in world space and consumed by CombatSystem.resolve().

## Entity that owns the hitbox (gets `on_hitbox_contact` callbacks).
var source: SimEntity
## Fighter credited with the hit (combo, ki); the victim can't be this one.
var attacker: Fighter
var move: MoveData
## Unique per activation of `source`; one contact per id and victim.
var hit_id: int = 0
## The activation connects with its first victim only (ki blasts, rush
## supers, throws); otherwise it hits every fighter it overlaps once.
var single_target: bool = false
## Capsule segment a-b with radius (a == b for spheres).
var a: Vector3
var b: Vector3
var radius: float = 0.5
## Where the attack comes from (guard angle check).
var origin: Vector3
## World axes used to orient knockback (attacker space -> world).
var forward: Vector3 = Vector3.FORWARD
var right: Vector3 = Vector3.RIGHT
var damage_mult: float = 1.0
## Scales the move's guard_ki_cost.
var guard_ki_mult: float = 1.0
## >0: a clean hit stuns (staggers) the victim this long instead of hitstun.
var stun_frames: int = 0
## A blocked hit crashes the guard outright.
var breaks_guard: bool = false
## Melee hitboxes (from the attacker's body) let a perfect duck stagger it.
var is_melee: bool = true
## First hit of a move that starts a string (not a cancel/chain out of a
## move that connected): only these can be guard-vanished.
var opens_string: bool = true
## Grab (MoveData.is_throw): can't be blocked, only broken.
var is_throw: bool = false
## Hits all around (MoveData.radial): each victim is pushed away from `origin`.
var radial: bool = false


## Attack direction as seen by a victim at `at` (ground plane): `forward`,
## or from `origin` toward the victim for a radial hitbox.
func forward_at(at: Vector3) -> Vector3:
	if not radial:
		return forward
	var d := Vector3(at.x - origin.x, 0.0, at.z - origin.z)
	return d.normalized() if d.length_squared() > 0.0001 else forward


## Knockback for a victim at `at`, attacker space -> world.
func world_knockback(at: Vector3) -> Vector3:
	var k := move.knockback
	var fwd := forward_at(at)
	var rgt := right if not radial else Vector3(-fwd.z, 0.0, fwd.x)
	return rgt * k.x + Vector3.UP * k.y + fwd * k.z
