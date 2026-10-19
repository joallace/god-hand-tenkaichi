class_name WaveConfig
extends Resource
## One wave of a co-op Waves run (CoopConfig.waves).

## Enemies in this wave (0 = CoopConfig.enemy_count).
@export var count: int = 0
## CPU level override (-1 = CoopConfig.enemy_level).
@export var level: int = -1
## Character override (&"" = CoopConfig.enemy_character).
@export var character: StringName = &""


func to_dict() -> Dictionary:
	return {"count": count, "level": level, "character": String(character)}


## Inverse of to_dict(); null on wrong types or an unknown character, numbers
## clamped (network/replay data).
static func from_dict(d: Variant) -> WaveConfig:
	if not d is Dictionary:
		return null
	var w := WaveConfig.new()
	var count_v: Variant = MatchConfig.dict_int(d, "count", 0, 0, Tuning.coop.max_enemy_count)
	var level_v: Variant = MatchConfig.dict_int(d, "level", -1, -1, Tuning.cpu.level_count() - 1)
	var ch: Variant = MatchConfig.dict_character(d, "character")
	if count_v == null or level_v == null or ch == null:
		return null
	w.count = count_v
	w.level = level_v
	w.character = ch
	return w
