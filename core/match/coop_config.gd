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
