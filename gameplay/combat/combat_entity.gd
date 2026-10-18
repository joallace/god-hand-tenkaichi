class_name CombatEntity
extends SimEntity
## A SimEntity that can own hitboxes (Fighter, KiBlast, Beam). CombatSystem
## only talks to this interface.

## Outcome of a hitbox touching a hurtbox (see Fighter.receive_hit).
enum Contact { NONE, HIT, BLOCKED, PERFECT_DODGE, THROW }

## Last hit id that made contact; an activation connects at most once.
var _last_contact_id: int = -1


## World-space hitboxes live this tick. Called by CombatSystem after all
## entities ticked.
func get_active_hitboxes() -> Array[Hitbox]:
	return []


func has_contacted(hit_id: int) -> bool:
	return hit_id == _last_contact_id


## Called once per (hitbox, victim) contact whose outcome isn't NONE.
func on_hitbox_contact(hb: Hitbox, _victim: Fighter, _outcome: Contact) -> void:
	_last_contact_id = hb.hit_id
