class_name MatchTuning
extends Resource
## Match rules defaults (data/tuning/match_rules.tres). A MatchConfig copies these and the menus may override.

@export var tick_rate: int = 60
@export_range(1, 5) var rounds_to_win: int = 2
## Round time in seconds. 0 = infinite.
@export_range(0, 999) var round_time_seconds: int = 99
@export var round_time_options: PackedInt32Array = PackedInt32Array([60, 99, 0])
@export var round_intro_frames: int = 90
@export var round_outro_frames: int = 150
@export var arena_radius: float = 18.0
@export var spawn_distance: float = 8.0
## Side-by-side spacing (m) of teammates on their team's spawn line.
@export var spawn_team_spacing: float = 2.5
