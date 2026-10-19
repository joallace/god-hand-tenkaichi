class_name EntityFactory
extends RefCounted
## Builds sim entities from spawn descriptors, so MatchDirector.load_state can
## recreate whatever existed in a snapshot (rollback) and future modes can
## spawn fighters mid-match.
##
## Descriptor (SimEntity.spawn_desc()):
##   {"type": StringName, "id": int (sim_id), "init": Dictionary}
## Types and their init:
##   &"fighter":  {slot, character_id, team (-1 = slot), cpu_level
##                (-1 = from the MatchConfig; >= 0 = spawned mid-match with
##                its own CpuInput, see MatchDirector.spawn_fighter)}
##   &"ki_blast": {caster: caster sim_id, move: MoveData resource_path}
##   &"beam":     same as ki_blast
## Two phases: create() builds the node from `init` alone; links to other
## entities (a projectile's caster) are restored by SimEntity.resolve_links()
## once every entity of the snapshot exists.

const FIGHTER := &"fighter"
const KI_BLAST := &"ki_blast"
const BEAM := &"beam"


static func create(desc: Dictionary) -> SimEntity:
	var init: Dictionary = desc.get("init", {})
	var e: SimEntity
	match desc["type"]:
		FIGHTER:
			e = create_fighter(init["slot"], init["character_id"], init.get("team", -1), init.get("cpu_level", -1))
		KI_BLAST:
			e = KiBlast.new()
		BEAM:
			e = Beam.new()
		_:
			push_error("EntityFactory: unknown entity type %s" % desc["type"])
			return null
	e.sim_id = desc.get("id", -1)
	e.spawn_init = init.duplicate()
	return e


static func fighter_desc(slot: int, character_id: StringName, team: int = -1, cpu_level: int = -1) -> Dictionary:
	return {"type": FIGHTER, "id": -1, "init": {
		"slot": slot, "character_id": character_id, "team": team, "cpu_level": cpu_level,
	}}


## A fighter node for `slot` (its def, visual and node name). team < 0 = the
## slot (1v1: two teams of one).
static func create_fighter(slot: int, character_id: StringName, team: int = -1, cpu_level: int = -1) -> Fighter:
	var f := CharacterRegistry.create_fighter(character_id)
	f.slot = slot
	f.name = "Fighter%d" % (slot + 1)
	f.spawn_init = fighter_desc(slot, character_id, team, cpu_level)["init"]
	f.team = team if team >= 0 else slot
	return f


## Resource path of a MoveData a projectile carries. Spawn moves are their
## own .tres files (tools/generate_moves.gd), so the path reloads the same
## cached resource.
static func move_ref(m: MoveData) -> String:
	if m == null:
		return ""
	if m.resource_path == "" or m.resource_path.contains("::"):
		push_error("EntityFactory: move %s has no file path; it can't be restored" % m.id)
	return m.resource_path


static func load_move(path: String) -> MoveData:
	return load(path) as MoveData if path != "" else null
