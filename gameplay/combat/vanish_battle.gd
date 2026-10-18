class_name VanishBattle
extends RefCounted
## Shared state of a vanish-escape ping-pong, referenced by both fighters.
##
## Exchange 0: the defender vanishes behind the attacker (from hitstun, or by
## a timed GUARD just before a hit, which opens cheaper). After
## each vanish the other fighter ("responder") gets a response window to
## vanish back. Each exchange costs more ki and the window shrinks. The battle
## ends when the responder doesn't answer in time, can't pay, or anyone is hit.

## Identifies the battle across save/load so both fighters re-share it.
var serial: int = 0
var exchange: int = 0
var vanisher_slot: int = -1
var responder_slot: int = -1
var active: bool = true
## Ki bars the opening exchange cost; later exchanges escalate from it.
var base_bars: float = 0.0


static func window_for(t: FighterTuning, exchange_index: int) -> int:
	return maxi(t.vanish_battle_window_start - t.vanish_battle_window_step * exchange_index,
		t.vanish_battle_window_min)


## Cost of a hitstun vanish escape battle's exchange.
static func cost_for(t: FighterTuning, exchange_index: int) -> float:
	return cost_from(t, t.vanish_escape_cost_bars, exchange_index)


static func cost_from(t: FighterTuning, opening_bars: float, exchange_index: int) -> float:
	return (opening_bars + exchange_index * t.vanish_battle_cost_step_bars) * t.ki_bar_size


## Cost of exchange `exchange_index` of this battle.
func cost(t: FighterTuning, exchange_index: int) -> float:
	return cost_from(t, base_bars, exchange_index)


func to_dict() -> Dictionary:
	return {"serial": serial, "exchange": exchange, "vanisher": vanisher_slot,
		"responder": responder_slot, "active": active, "base_bars": base_bars}


func apply_dict(d: Dictionary) -> void:
	serial = d["serial"]
	exchange = d["exchange"]
	vanisher_slot = d["vanisher"]
	responder_slot = d["responder"]
	active = d["active"]
	base_bars = d["base_bars"]


static func from_dict(d: Dictionary) -> VanishBattle:
	var b := VanishBattle.new()
	b.apply_dict(d)
	return b
