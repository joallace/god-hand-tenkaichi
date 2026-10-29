class_name CameraTuning
extends Resource
## Lock-on fighter camera (presentation only). Edit data/tuning/camera.tres.
## Distances in meters, damping values are exponential rates (1/s, higher =
## snappier), durations in seconds.

@export_group("Lens")
@export_range(20.0, 120.0) var fov_split: float = 66.0
@export_range(20.0, 120.0) var fov_single: float = 58.0
@export var near: float = 0.05
@export var far: float = 500.0

@export_group("Framing")
## Distance behind the fighter = base + separation * per_meter, clamped.
@export var base_distance: float = 4.4
@export var distance_per_meter: float = 0.15
@export var min_distance: float = 4.0
@export var max_distance: float = 9.0
@export var base_height: float = 2.2
@export var height_per_meter: float = 0.05
@export var max_height: float = 3.4
## Sideways (right) offset for the over-the-shoulder look.
@export var shoulder_offset: float = 0.75
## Height of the look-at point above the ground.
@export var look_height: float = 1.0
## Where the camera looks between fighter (0) and opponent (1).
@export_range(0.0, 1.0) var look_bias: float = 0.45
## Look point never further than this from the fighter.
@export var max_look_ahead: float = 7.0

@export_group("Free roam")
## TARGET held (Fighter.is_free_roaming): God Hand camera behind the
## fighter's facing, looking this far ahead of it. Shoulder offset and
## position/look smoothing are shared with the lock-on framing.
@export var free_roam_distance: float = 3.8
@export var free_roam_height: float = 2.0
@export var free_roam_look_ahead: float = 4.0
## Yaw damping while free roaming: stiffer than yaw_damping so the view
## stays behind a turning fighter (steady lag = turn speed / this).
@export var free_roam_yaw_damping: float = 16.0

@export_group("Smoothing")
@export var position_damping: float = 9.0
@export var look_damping: float = 12.0
@export var yaw_damping: float = 7.0
## Caps yaw speed so a cross-up / teleport swings round instead of popping.
@export var max_yaw_speed_deg: float = 600.0

@export_group("Limits")
## Camera stays within arena_radius + this margin (horizontal).
@export var radius_margin: float = 7.0
@export var min_camera_height: float = 0.5

@export_group("Shake (trauma based)")
@export var shake_max_offset: float = 0.3
@export var shake_max_roll_deg: float = 2.5
@export var shake_frequency: float = 24.0
## Trauma lost per second.
@export var trauma_decay: float = 1.8
@export var trauma_hit_light: float = 0.22
@export var trauma_hit_heavy: float = 0.5
@export var trauma_hit_blocked: float = 0.1
@export var trauma_guard_break: float = 0.55
@export var trauma_push_off: float = 0.25
@export var trauma_counter_guard: float = 0.3
@export var trauma_throw_break: float = 0.25
@export var trauma_ground_bounce: float = 0.4
@export var trauma_ko: float = 0.85
@export var trauma_ultimate: float = 0.3
## The view of the fighter NOT directly involved gets this fraction.
@export_range(0.0, 1.0) var shake_other_view_scale: float = 0.6

@export_group("Zoom punch")
## FOV delta (degrees, negative = zoom in) on the dodger's perfect dodge.
@export var perfect_dodge_fov_punch: float = -9.0
@export var heavy_hit_fov_punch: float = 2.5
## FOV delta on the countering fighter's view when a counter stance catches a hit.
@export var counter_guard_fov_punch: float = -6.0
@export var fov_recover_damping: float = 5.0

@export_group("Ultimate cinematic")
## Both cameras sweep around the fighter starting the ultimate, then blend back.
@export var ultimate_duration: float = 1.8
## Sweep angle around the user, starting from behind them.
@export var ultimate_orbit_deg: float = 150.0
@export var ultimate_distance: float = 3.4
@export var ultimate_height: float = 1.5
@export var ultimate_look_height: float = 1.2
## Fraction of the duration spent blending in (and again out).
@export_range(0.05, 0.5) var ultimate_blend: float = 0.2
