class_name TargetingTuning
extends Resource
## How a human fighter picks its target among several enemies (Targeting).
## Edit data/tuning/targeting.tres. Scores are unitless: higher = better.

## Score lost per radian between the fighter's forward and the candidate.
@export_range(0.0, 10.0) var angle_weight: float = 1.0
## Score lost per meter of horizontal distance.
@export_range(0.0, 10.0) var distance_weight: float = 0.15
## Score bonus for a candidate currently attacking this fighter.
@export_range(0.0, 10.0) var attacking_bonus: float = 0.6
## Auto pick keeps the current target unless another beats it by this much.
@export_range(0.0, 10.0) var hysteresis_margin: float = 0.35
## Frames between automatic re-evaluations while not manually locked.
@export_range(1, 600) var retarget_check_frames: int = 20
## |stick x| (fraction of full tilt) that turns a TARGET tap counter-clockwise
## (stick left) instead of clockwise (neutral / right).
@export_range(0.0, 1.0) var cycle_stick_threshold: float = 0.5
## TARGET held this many frames = free roam (God Hand controls and camera,
## no auto-facing) until it is let go; a shorter press is a tap (cycles the
## target when released).
@export_range(1, 120) var free_roam_hold_frames: int = 12
