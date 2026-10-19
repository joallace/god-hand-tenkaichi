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
## Stable id from MatchDirector's counter (spawn order); orders ticks and
## names the entity in snapshots. -1 until registered.
var sim_id: int = -1
## The EntityFactory init this entity is rebuilt from (see spawn_desc()).
var spawn_init: Dictionary = {}


func sim_tick(_tick: int) -> void:
	pass


## EntityFactory type name (&"fighter", &"ki_blast", ...). Override.
func spawn_type() -> StringName:
	return &""


## How to rebuild this entity: an EntityFactory descriptor.
func spawn_desc() -> Dictionary:
	return {"type": spawn_type(), "id": sim_id, "init": spawn_init.duplicate()}


## Second construction phase after a factory rebuild: look up the other
## entities named in spawn_init (every entity of the snapshot exists by now).
func resolve_links(_director: MatchDirector) -> void:
	pass


func save_state() -> Dictionary:
	return {"pos": global_position, "rot": global_basis}


func load_state(s: Dictionary) -> void:
	global_position = s["pos"]
	global_basis = s["rot"]
