class_name VfxTuning
extends Resource
## Visual effects (presentation only). Edit data/tuning/vfx.tres.
## Durations in seconds, sizes in meters.

@export_group("Hit sparks")
@export var hit_color: Color = Color(1.0, 0.85, 0.35)
@export var heavy_hit_color: Color = Color(1.0, 0.45, 0.1)
@export var blocked_color: Color = Color(0.35, 0.7, 1.0)
@export var hit_flash_size: float = 0.7
@export var heavy_flash_size: float = 1.4
@export var hit_duration: float = 0.18
@export var heavy_duration: float = 0.28
@export var spark_count_light: int = 6
@export var spark_count_heavy: int = 12
@export var spark_speed: float = 4.5
@export var spark_size: float = 0.09
## Used when a hit event has no position: fighter origin + this height.
@export var fallback_hit_height: float = 1.2

@export_group("Perfect dodge")
@export var afterimage_color: Color = Color(0.5, 0.9, 1.0, 0.5)
@export var afterimage_duration: float = 0.45
@export var afterimage_max_meshes: int = 24
@export var dodge_tint_color: Color = Color(0.4, 0.85, 1.0, 0.28)
@export var dodge_tint_duration: float = 0.35

@export_group("Teleport / vanish")
@export var teleport_color: Color = Color(0.85, 0.95, 1.0)
@export var teleport_flash_size: float = 1.4
@export var teleport_duration: float = 0.22
@export var vanish_ring_size: float = 2.2

@export_group("Guard break / KO / ultimate")
@export var guard_break_color: Color = Color(1.0, 0.6, 0.1)
@export var guard_break_size: float = 2.0
@export var guard_break_duration: float = 0.4
@export var ko_color: Color = Color(1.0, 1.0, 0.9)
@export var ko_size: float = 3.0
@export var ko_duration: float = 0.5
@export var ultimate_color: Color = Color(1.0, 0.9, 0.3)
@export var ultimate_tint_color: Color = Color(1.0, 0.85, 0.3, 0.3)
@export var ultimate_tint_duration: float = 0.5
