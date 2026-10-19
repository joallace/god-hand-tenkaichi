class_name CoopConfig
extends Resource
## Co-op run setup (MatchConfig.coop, null outside Mode.COOP). Built by the
## join screen; defaults come from Tuning.coop. Humans and the optional CPU
## ally are team 0 (MatchConfig.players); enemies are team 1, created by the
## director from this config (not listed in players). See SPEC.md.

enum Structure { BRAWL, WAVES }

@export var structure: Structure = Structure.BRAWL
## Brawl: total enemies. Waves: enemies per wave unless the wave overrides it.
@export var enemy_count: int = 4
## Waves mode: one entry per wave (empty + endless = follow Tuning.coop curves).
@export var waves: Array[WaveConfig] = []
@export var endless: bool = false
## Index into Tuning.cpu.level_names (-1 = Tuning.cpu.default_level).
@export var enemy_level: int = -1
## &"" = random character per enemy (seeded by MatchConfig.rng_seed).
@export var enemy_character: StringName = &""
## Optional CPU ally on team 0 (added to MatchConfig.players by the menu as a
## CPU slot; these record the choice for "Retry").
@export var ally_enabled: bool = false
@export var ally_level: int = -1
@export var ally_character: StringName = &""


## Plain-data copy (int/bool/String/Array only) for the wire and replay files.
func to_dict() -> Dictionary:
	var ws: Array = []
	for w in waves:
		ws.append(w.to_dict())
	return {
		"structure": structure, "enemy_count": enemy_count, "waves": ws, "endless": endless,
		"enemy_level": enemy_level, "enemy_character": String(enemy_character),
		"ally_enabled": ally_enabled, "ally_level": ally_level, "ally_character": String(ally_character),
	}


## Inverse of to_dict(); null on wrong types / unknown characters, numbers
## clamped to the menu limits (Tuning.coop.max_enemy_count, max_wave_count).
static func from_dict(d: Variant) -> CoopConfig:
	if not d is Dictionary:
		return null
	var c := CoopConfig.new()
	var max_level := Tuning.cpu.level_count() - 1
	var structure_v: Variant = MatchConfig.dict_int(d, "structure", Structure.BRAWL, 0, Structure.size() - 1, false)
	var count_v: Variant = MatchConfig.dict_int(d, "enemy_count", c.enemy_count, 1, Tuning.coop.max_enemy_count)
	var level_v: Variant = MatchConfig.dict_int(d, "enemy_level", -1, -1, max_level)
	var ally_level_v: Variant = MatchConfig.dict_int(d, "ally_level", -1, -1, max_level)
	var enemy_ch: Variant = MatchConfig.dict_character(d, "enemy_character")
	var ally_ch: Variant = MatchConfig.dict_character(d, "ally_character")
	var endless_v: Variant = d.get("endless", false)
	var ally_v: Variant = d.get("ally_enabled", false)
	var ws: Variant = d.get("waves", [])
	if structure_v == null or count_v == null or level_v == null or ally_level_v == null or enemy_ch == null \
			or ally_ch == null or not endless_v is bool or not ally_v is bool or not ws is Array \
			or (ws as Array).size() > Tuning.coop.max_wave_count:
		return null
	for wd: Variant in ws:
		var w := WaveConfig.from_dict(wd)
		if w == null:
			return null
		c.waves.append(w)
	c.structure = structure_v
	c.enemy_count = count_v
	c.enemy_level = level_v
	c.ally_level = ally_level_v
	c.enemy_character = enemy_ch
	c.ally_character = ally_ch
	c.endless = endless_v
	c.ally_enabled = ally_v
	return c
