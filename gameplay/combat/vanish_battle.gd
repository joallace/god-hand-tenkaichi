class_name VanishBattle
extends RefCounted
## Shared state of a vanish-escape ping-pong, referenced by both fighters.
##
## Exchange 0: the defender (in hitstun) vanishes behind the attacker. After
## each vanish the other fighter ("responder") gets a response window to
## vanish back. Each exchange costs more ki and the window shrinks. The battle
## ends when the responder doesn't answer in time, can't pay, or anyone is hit.

## Identifies the battle across save/load so both fighters re-share it.
var serial: int = 0
var exchange: int = 0
var vanisher_slot: int = -1
var responder_slot: int = -1
var active: bool = true


static func window_for(t: FighterTuning, exchange_index: int) -> int:
	return maxi(t.vanish_battle_window_start - t.vanish_battle_window_step * exchange_index,
		t.vanish_battle_window_min)


static func cost_for(t: FighterTuning, exchange_index: int) -> float:
	return (t.vanish_escape_cost_bars + exchange_index * t.vanish_battle_cost_step_bars) * t.ki_bar_size


func to_dict() -> Dictionary:
	return {"serial": serial, "exchange": exchange, "vanisher": vanisher_slot,
		"responder": responder_slot, "active": active}


func apply_dict(d: Dictionary) -> void:
	serial = d["serial"]
	exchange = d["exchange"]
	vanisher_slot = d["vanisher"]
	responder_slot = d["responder"]
	active = d["active"]


static func from_dict(d: Dictionary) -> VanishBattle:
	var b := VanishBattle.new()
	b.apply_dict(d)
	return b
