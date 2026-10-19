class_name WaveConfig
extends Resource
## One wave of a co-op Waves run (CoopConfig.waves).

## Enemies in this wave (0 = CoopConfig.enemy_count).
@export var count: int = 0
## CPU level override (-1 = CoopConfig.enemy_level).
@export var level: int = -1
## Character override (&"" = CoopConfig.enemy_character).
@export var character: StringName = &""
