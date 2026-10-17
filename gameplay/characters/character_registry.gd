class_name CharacterRegistry
extends RefCounted
## Maps character ids to CharacterDef resources (data/characters/<id>.tres)
## and builds Fighter nodes from them. Add a character = add its def to the
## generator (tools/generate_moves.gd) and its id to IDS.

const DIR := "res://data/characters/"
const IDS: Array[StringName] = [&"brawler"]


static func ids() -> Array[StringName]:
	return IDS.duplicate()


static func load_def(id: StringName) -> CharacterDef:
	var path := DIR + String(id) + ".tres"
	if not ResourceLoader.exists(path):
		push_error("CharacterRegistry: missing %s (run tools/generate_moves.gd)" % path)
		return CharacterDef.new()
	return load(path) as CharacterDef


static func display_name(id: StringName) -> String:
	var d := load_def(id)
	return d.display_name if d.display_name != "" else String(id).capitalize()


## A fighter with its def and placeholder visual. The caller sets `slot`
## before adding it to the tree (the tint depends on it).
static func create_fighter(id: StringName) -> Fighter:
	var f := Fighter.new()
	f.def = load_def(id)
	var visual := FighterVisual.new()
	visual.name = "Visual"
	f.add_child(visual)
	return f
