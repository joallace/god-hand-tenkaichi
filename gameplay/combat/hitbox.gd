class_name Hitbox
extends RefCounted
## A live hitbox for one tick, built by its source (Fighter, KiBlast, Beam)
## in world space and consumed by CombatSystem.resolve().

## Entity that owns the hitbox (gets `on_hitbox_contact` callbacks).
var source: SimEntity
## Fighter credited with the hit (combo, ki); the victim can't be this one.
var attacker: Fighter
var move: MoveData
## Unique per activation of `source`; one contact per id.
var hit_id: int = 0
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
var guard_damage_mult: float = 1.0
## >0: a clean hit stuns (staggers) the victim this long instead of hitstun.
var stun_frames: int = 0
## A blocked hit breaks the guard outright.
var breaks_guard: bool = false
## Melee hitboxes (from the attacker's body) let a perfect duck stagger it.
var is_melee: bool = true


func world_knockback() -> Vector3:
	var k := move.knockback
	return right * k.x + Vector3.UP * k.y + forward * k.z
