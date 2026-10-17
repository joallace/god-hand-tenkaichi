class_name ArenaTuning
extends Resource
## Arena visuals (presentation only; the play radius itself is
## Tuning.match_rules.arena_radius). Edit data/tuning/arena.tres.

@export_group("Ground")
@export var tile_size: float = 2.0
@export var tile_color_a: Color = Color(0.82, 0.74, 0.58)
@export var tile_color_b: Color = Color(0.7, 0.6, 0.45)
@export var grout_color: Color = Color(0.4, 0.33, 0.25)
@export var center_mark_color: Color = Color(0.85, 0.3, 0.15)
@export var outer_ground_color: Color = Color(0.45, 0.62, 0.3)
@export var outer_ground_size: float = 400.0

@export_group("Ring edge & wall")
@export var edge_color: Color = Color(0.45, 0.4, 0.36)
@export var edge_thickness: float = 0.6
@export var wall_color: Color = Color(0.4, 0.8, 1.0, 0.6)
@export var wall_height: float = 4.0
## Wall pulse speed (scroll of the energy bands).
@export var wall_scroll_speed: float = 0.6

@export_group("Scenery")
@export var scenery_seed: int = 1337
@export var boulder_count: int = 10
@export var pillar_count: int = 6
## Scenery distance from the ring edge.
@export var scenery_min_gap: float = 4.0
@export var scenery_max_gap: float = 26.0
@export var rock_color: Color = Color(0.55, 0.5, 0.45)
@export var mountain_count: int = 9
@export var mountain_distance: float = 150.0
@export var mountain_color: Color = Color(0.45, 0.5, 0.6)

@export_group("Sky & light")
@export var sky_top_color: Color = Color(0.15, 0.45, 0.95)
@export var sky_horizon_color: Color = Color(0.7, 0.85, 1.0)
@export var ground_bottom_color: Color = Color(0.3, 0.35, 0.3)
@export var ground_horizon_color: Color = Color(0.7, 0.8, 0.9)
@export var sun_energy: float = 1.3
@export var sun_pitch_deg: float = -50.0
@export var sun_yaw_deg: float = 35.0
@export var ambient_energy: float = 0.8
@export var shadow_max_distance: float = 60.0
@export var glow_enabled: bool = true
