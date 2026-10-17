class_name SimEntity
extends Node3D
## Anything that participates in the fixed-tick simulation (fighters,
## projectiles, beams). MatchDirector owns the order and calls `sim_tick`;
## entities must NOT use _process/_physics_process for gameplay (visual-only
## smoothing is fine). All gameplay state must round-trip through
## save_state/load_state so rollback netcode can be added later.

## Set by MatchDirector when registered.
var director: MatchDirector
## Set to true to have the director remove this entity after the tick.
var sim_dead := false


func sim_tick(_tick: int) -> void:
	pass


func save_state() -> Dictionary:
	return {"pos": global_position, "rot": global_basis}


func load_state(s: Dictionary) -> void:
	global_position = s["pos"]
	global_basis = s["rot"]
