class_name CombatEntity
extends SimEntity
## A SimEntity that can own hitboxes (Fighter, KiBlast, Beam). CombatSystem
## only talks to this interface.

## Outcome of a hitbox touching a hurtbox (see Fighter.receive_hit).
enum Contact { NONE, HIT, BLOCKED, PERFECT_DODGE, THROW }

## Contact bookkeeping for the current activation: its hit id and the slots
## of the fighters it already connected with. An activation connects once per
## victim (crowds: one strike can hit several fighters), or only once at all
## for a Hitbox.single_target one (ki blasts, rush supers, throws).
var _last_contact_id: int = -1
var _contacted_slots: PackedInt32Array = PackedInt32Array()


## World-space hitboxes live this tick. Called by CombatSystem after all
## entities ticked.
func get_active_hitboxes() -> Array[Hitbox]:
	return []


## True when `hb` may not connect with `victim` (null = with anyone new):
## the activation already touched that victim, or it is single-target and
## already touched someone.
func has_contacted(hb: Hitbox, victim: Fighter = null) -> bool:
	if hb.hit_id != _last_contact_id or _contacted_slots.is_empty():
		return false
	if hb.single_target:
		return true
	return victim != null and victim.slot in _contacted_slots


## Called once per (hitbox, victim) contact whose outcome isn't NONE.
func on_hitbox_contact(hb: Hitbox, victim: Fighter, _outcome: Contact) -> void:
	if hb.hit_id != _last_contact_id:
		_last_contact_id = hb.hit_id
		_contacted_slots = PackedInt32Array()
	if victim != null:
		_contacted_slots.append(victim.slot)


## Forget every contact (new activation run: spawn, round reset).
func clear_contacts() -> void:
	_last_contact_id = -1
	_contacted_slots = PackedInt32Array()


func save_contacts(s: Dictionary) -> void:
	s["last_contact"] = _last_contact_id
	s["contacted"] = _contacted_slots.duplicate()


func load_contacts(s: Dictionary) -> void:
	_last_contact_id = s["last_contact"]
	_contacted_slots = s["contacted"].duplicate()
