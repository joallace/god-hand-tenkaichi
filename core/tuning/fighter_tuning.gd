class_name FighterTuning
extends Resource
## Core combat numbers shared by all fighters. Durations are in sim frames
## (60/s), distances in meters, speeds in m/s. Per-move numbers live in
## MoveData resources instead. Edit data/tuning/fighter.tres.

@export_group("Health & Ki")
@export var max_health: float = 1000.0
@export var ki_bar_size: float = 100.0
@export_range(1, 10) var ki_bars: int = 5
@export var ki_start: float = 100.0
## Ki gained per frame while holding charge (≈1 bar / 1.2 s).
@export var ki_charge_per_frame: float = 100.0 / 72.0
@export var ki_gain_on_hit_dealt: float = 4.0
@export var ki_gain_on_hit_taken: float = 3.0
@export var ki_gain_on_perfect_dodge: float = 15.0

@export_group("Movement")
@export var walk_speed: float = 6.0
@export var dash_speed: float = 16.0
@export var dash_frames: int = 14
@export var jump_velocity: float = 7.5
@export var gravity: float = 24.0
@export var body_radius: float = 0.45
@export var turn_speed_deg: float = 720.0
## Hurtbox capsule heights (m): standing, ducking, lying on the ground.
@export var body_height: float = 1.8
@export var duck_height: float = 0.9
@export var lying_height: float = 0.45
## Deceleration (m/s^2) applied to grounded knockback / slide velocity.
@export var ground_friction: float = 30.0

@export_group("Dodge")
@export var dodge_total_frames: int = 24
@export var dodge_invuln_start: int = 1
@export var dodge_invuln_frames: int = 12
## Hit attempted during the first N frames of a dodge = perfect dodge.
@export var perfect_dodge_frames: int = 4
@export var perfect_dodge_counter_frames: int = 30
@export var sway_distance: float = 1.6
@export var backflip_distance: float = 2.8
@export var duck_cooldown_frames: int = 0
## Frames over which sway/backflip travel their distance.
@export var dodge_move_frames: int = 12
## Last N frames of an attack's recovery can be canceled into a dodge.
@export var dodge_cancel_recovery_frames: int = 8
## Damage multiplier of the counter attack after a perfect dodge.
@export var perfect_dodge_counter_damage_mult: float = 1.5
## Global hitstop when a perfect dodge triggers (dramatic beat).
@export var perfect_dodge_hitstop: int = 6
## Stagger applied to an attacker whose melee hit was perfectly ducked.
@export var perfect_duck_stagger_frames: int = 40

@export_group("Guard")
@export var guard_chip_ratio: float = 0.15
@export var guard_stun_frames: int = 10
@export var guard_break_stun_frames: int = 50
## Max guard health; heavies/supers drain it, breaking at 0.
@export var guard_health: float = 100.0
@export var guard_regen_per_frame: float = 0.4
## Hits within this angle (degrees, either side of facing) can be blocked.
@export var guard_half_angle_deg: float = 80.0
## Fraction of a move's knockback applied as pushback when blocked.
@export var guard_pushback_ratio: float = 0.6

@export_group("Hit reactions")
@export var hitstop_light: int = 4
@export var hitstop_heavy: int = 8
## Frames spent lying on the ground after landing, before getting up.
@export var knockdown_frames: int = 24
@export var wakeup_invuln_frames: int = 20
## Length of the get-up (Wakeup) state; invuln may outlast it.
@export var wakeup_frames: int = 12
## Damage scaling per hit in a combo (multiplied), with a floor.
@export var combo_scaling: float = 0.92
@export var combo_scaling_min: float = 0.35

@export_group("Strikes")
## Stick Y beyond this picks the high (forward) / low (back) HEAVY variant.
@export var strike_dir_threshold: float = 0.5

@export_group("Charge strikes")
## Holding LIGHT/HEAVY this many frames turns the attack into its charge strike.
@export var charge_hold_frames: int = 12
## Charge ratio from which a clean hit stuns the victim...
@export_range(0.0, 1.0) var charge_stun_ratio: float = 0.5
## ...for this many frames, growing to the max at full charge.
@export var charge_stun_frames_min: int = 36
@export var charge_stun_frames_max: int = 60
## Charge ratio from which a blocked hit breaks the guard outright.
@export_range(0.0, 1.0) var charge_break_ratio: float = 1.0

@export_group("Teleport & Vanish")
@export var teleport_cost_bars: float = 1.0
@export var teleport_max_per_combo: int = 2
@export var teleport_behind_distance: float = 1.4
@export var teleport_frames: int = 8
## After reappearing, frames in which a follow-up attack still links.
@export var teleport_followup_window: int = 20
## Frames after one of your hits lands in which TELEPORT can be used.
@export var teleport_hit_window: int = 30
@export var vanish_escape_cost_bars: float = 2.0
## Each successive exchange in a vanish battle costs this many extra bars...
@export var vanish_battle_cost_step_bars: float = 0.5
## ...and shrinks the response window by this many frames.
@export var vanish_battle_window_start: int = 18
@export var vanish_battle_window_step: int = 3
@export var vanish_battle_window_min: int = 6

@export_group("Specials")
@export var super1_cost_bars: float = 2.0
@export var super2_cost_bars: float = 2.0
@export var ultimate_cost_bars: float = 5.0
@export var ki_blast_cost: float = 10.0
## Stick Y beyond this picks forward/back SPECIAL variants.
@export var special_dir_threshold: float = 0.5
## Global freeze before the ultimate's startup (cinematic beat).
@export var ultimate_freeze_frames: int = 45
