class_name VfxTuning
extends Resource
## Visual effects (presentation only). Edit data/tuning/vfx.tres.
## Durations in seconds, sizes in meters.

@export_group("Hit sparks")
@export var hit_color: Color = Color(1.0, 0.85, 0.35)
@export var heavy_hit_color: Color = Color(1.0, 0.45, 0.1)
@export var blocked_color: Color = Color(0.35, 0.7, 1.0)
## Blocked hit taken with a ki guard (drains ki).
@export var ki_guard_color: Color = Color(0.4, 1.0, 0.95)
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

@export_group("Guard reactions / throws / taunt")
## Push-off: the guard repels the attacker (spark + ring at the defender).
@export var push_off_color: Color = Color(0.75, 0.95, 1.0)
@export var push_off_size: float = 1.6
@export var push_off_duration: float = 0.3
## Counter stance catching a hit.
@export var counter_color: Color = Color(1.0, 0.95, 0.5)
@export var counter_size: float = 1.8
@export var counter_duration: float = 0.3
@export var counter_tint_color: Color = Color(1.0, 0.95, 0.5, 0.25)
@export var counter_tint_duration: float = 0.3
## Throw break: both fighters knocked apart.
@export var throw_break_color: Color = Color(1.0, 1.0, 1.0)
@export var throw_break_size: float = 1.5
@export var throw_break_duration: float = 0.25
## Grab connecting.
@export var throw_color: Color = Color(1.0, 0.75, 0.4)
@export var throw_size: float = 0.9
@export var throw_duration: float = 0.2
## Dust ring where a fighter bounces off the floor (height above the feet).
@export var ground_bounce_color: Color = Color(0.85, 0.75, 0.6, 0.8)
@export var ground_bounce_size: float = 2.6
@export var ground_bounce_duration: float = 0.35
@export var ground_bounce_height: float = 0.1
## Small ki burst when a taunt finishes and pays out ki.
@export var taunt_ki_color: Color = Color(0.45, 0.95, 1.0, 0.7)
@export var taunt_ki_size: float = 1.6
@export var taunt_ki_duration: float = 0.4

@export_group("Co-op")
## Enemy appearing at the ring edge (reappear-style flash + ring).
@export var entry_color: Color = Color(1.0, 0.45, 0.35)
@export var entry_size: float = 1.6
@export var entry_duration: float = 0.35
## Downed / revived bursts on the fighter.
@export var downed_color: Color = Color(1.0, 0.55, 0.2, 0.8)
@export var downed_size: float = 1.4
@export var downed_duration: float = 0.35
@export var revive_color: Color = Color(0.4, 1.0, 0.5, 0.8)
@export var revive_size: float = 2.0
@export var revive_duration: float = 0.45
## A third party breaking a throw / vanish battle.
@export var lock_broken_color: Color = Color(1.0, 1.0, 1.0)
@export var lock_broken_size: float = 1.5
@export var lock_broken_duration: float = 0.3
## KO'd co-op enemies stay solid for this fraction of Tuning.coop.enemy_fade_frames,
## then fade out over the rest.
@export_range(0.0, 1.0) var ko_fade_delay_ratio: float = 0.4
