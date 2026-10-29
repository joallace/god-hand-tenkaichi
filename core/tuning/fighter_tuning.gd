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
## Charge wind-up (BT3 style): frames after CHARGE starts before ki fills.
## Specials (CHARGE + HEAVY / SPECIAL) already work during it; releasing
## early still pays the release lag, so a CHARGE tap costs time, gains nothing.
@export var charge_windup_frames: int = 10
## Release lag: frames after letting go of CHARGE (or in the wind-up) where
## the fighter can only dodge or guard (no walk, attack, jump, dash, charge).
## Guarding doesn't skip it: letting go of GUARD early resumes the lag.
@export var charge_release_lag_frames: int = 12
@export var ki_gain_on_hit_dealt: float = 4.0
@export var ki_gain_on_hit_taken: float = 3.0
@export var ki_gain_on_perfect_dodge: float = 15.0

@export_group("Movement")
@export var walk_speed: float = 6.0
## Forward dash (DASH): startup ramping up to dash_speed, travel at full
## speed, then a punishable end lag braking to a stop. LIGHT/HEAVY = dash
## attack in the travel only (a press in the startup is buffered for it);
## a dodge cancels any phase. ~4 m in total.
@export var dash_speed: float = 16.0
## Startup: speed ramps linearly from dash_speed / dash_startup_frames up to
## dash_speed on its last frame. No dash attack yet.
@export var dash_startup_frames: int = 6
## Travel at full dash_speed (the dash attack window).
@export var dash_frames: int = 7
## End lag: speed falls linearly to 0; only a dodge gets out of it.
@export var dash_end_lag_frames: int = 10
## After a dash ends (any way: finished, attack, dodge, hit), DASH is ignored
## this many frames, so dashes can't be chained back to back (a press in
## its last InputTuning.input_buffer_frames is buffered and fires at the end).
@export var dash_cooldown_frames: int = 10
@export var jump_velocity: float = 7.5
@export var gravity: float = 24.0
@export var body_radius: float = 0.45
@export var turn_speed_deg: float = 720.0
## Turn speed while an attack tracks the opponent during startup. Slower than
## turn_speed_deg so an early sway outruns it (God Hand enemies ~340 deg/s).
@export var attack_track_turn_deg: float = 360.0
## Moves without an explicit track_frames stop tracking this many frames
## before their first active frame (the swing commits).
@export var attack_track_lock_frames: int = 2
## Free roam (TARGET held, God Hand style): stick x turns the fighter at this
## rate, stick y walks along its facing (backward at walk_speed * ratio).
@export var free_roam_turn_speed_deg: float = 240.0
@export_range(0.0, 1.0) var free_roam_back_speed_ratio: float = 0.6
## Free roam TARGET tap: 180 degree turn over this many frames (rooted).
@export_range(1, 60) var free_roam_quick_turn_frames: int = 8
## Hurtbox capsule heights (m): standing, ducking, lying on the ground.
@export var body_height: float = 1.8
@export var duck_height: float = 0.9
@export var lying_height: float = 0.45
## Deceleration (m/s^2) applied to grounded knockback / slide velocity.
@export var ground_friction: float = 30.0

@export_group("Dodge")
## Per-direction timings follow God Hand's dodges measured in PCSX2
## (docs/god_hand_reference.md#dodges-measured-in-pcsx2): a short, quickly
## repeatable duck, a mid-length side sway, a long committal back-sway.
## Invulnerability lasts dodge_invuln_start .. +<dir>_invuln_frames (GH's
## invuln is still unmeasured); every frame between its end and
## <dir>_chain_from_frame stays punishable, so endless chains aren't safe.
## total = back to neutral, chain_from = earliest next dodge, attack_from =
## when a LIGHT/HEAVY pressed mid-dodge fires.
@export var dodge_invuln_start: int = 1
## Duck (GH: low +2..+10, upright +16..+20, re-duck every 8-10).
@export var duck_total_frames: int = 18
@export var duck_invuln_frames: int = 6
@export var duck_chain_from_frame: int = 10
@export var duck_attack_from_frame: int = 10
## HEAVY queued during a duck fires the duck kick (CharacterDef.duck_heavy)
## from this frame: still in the crouch, right after the duck's invuln.
@export var duck_heavy_from_frame: int = 7
## Side sway (GH: lunge +2..+10/+14, upright +16..+22, next sway at +26).
@export var sway_total_frames: int = 26
@export var sway_invuln_frames: int = 12
@export var sway_move_frames: int = 12
@export var sway_chain_from_frame: int = 26
@export var sway_attack_from_frame: int = 18
## Back-sway (GH: lands +26, upright +34..+36, next back-sway at +30).
@export var backflip_total_frames: int = 36
@export var backflip_invuln_frames: int = 20
@export var backflip_move_frames: int = 26
@export var backflip_chain_from_frame: int = 30
@export var backflip_attack_from_frame: int = 30
## Hit attempted during the first N frames of a dodge = perfect dodge.
@export var perfect_dodge_frames: int = 4
@export var perfect_dodge_counter_frames: int = 30
@export var sway_distance: float = 1.6
@export var backflip_distance: float = 2.8
@export var duck_cooldown_frames: int = 0
## Last N frames of an attack's recovery can be canceled into a dodge.
@export var dodge_cancel_recovery_frames: int = 8
## Damage multiplier of the counter attack after a perfect dodge.
@export var perfect_dodge_counter_damage_mult: float = 1.5
## Global hitstop when a perfect dodge triggers (dramatic beat).
@export var perfect_dodge_hitstop: int = 6
## Stagger applied to an attacker whose melee hit was perfectly ducked.
@export var perfect_duck_stagger_frames: int = 40
## A dodge flick from <dir>_chain_from_frame (or any frame of a perfect-dodge
## counter window) chains into another dodge, at most dodge_chain_max times
## in a row; 0 = no cap (GH: 9 back-sways in a row, no lockout). A queued
## LIGHT/HEAVY fires at <dir>_attack_from_frame, or at once in a counter
## window.
@export var dodge_chain_max: int = 0

@export_group("Guard")
## BT3 guard: no guard meter. Each move has a GuardResult per guard pose
## (MoveData.guard_results); KI_GUARD results drain ki and an empty gauge
## crashes the guard (GUARD_BREAK state).
@export var guard_chip_ratio: float = 0.15
## Chip damage never takes health below this (chip can't KO).
@export var chip_min_health: float = 1.0
## Guard crash (ki emptied by a ki guard, or a full-charge smash) length...
@export var guard_break_stun_frames: int = 75
## ...and the ki refilled when it ends, so the next guard can hold a moment.
@export var guard_crash_ki_refill: float = 50.0
## Each LIGHT/HEAVY/GUARD/JUMP press shortens a guard crash or stagger by
## this many frames (mash out).
@export var stun_mash_frames: int = 6
## Hits within this angle (degrees, either side of facing) can be blocked.
@export var guard_half_angle_deg: float = 80.0
## Fraction of a move's knockback applied as pushback when blocked...
@export var guard_pushback_ratio: float = 0.6
## ...scaled again on KI_GUARD / PUSH_OFF results (BT3: half push).
@export var ki_guard_push_ratio: float = 0.5
## A new stick pose (forward = high, neutral = mid, back = low) must be held
## this many frames before a held guard switches to it. Entering the guard
## takes the held pose at once.
@export var guard_pose_switch_frames: int = 6
## PUSH_OFF / PUSH_STOP: the attacker recoils for this long at this speed...
@export var push_off_recoil_frames: int = 20
@export var push_off_recoil_speed: float = 4.0
## ...the defender gains this much ki...
@export var ki_gain_on_push_off: float = 10.0
## ...and PUSH_STOP also freezes both fighters (global hitstop).
@export var push_stop_freeze_frames: int = 5
## Counter guard: stick forward + LIGHT while guarding enters a counter
## stance; the first hit of a string landing in its first N frames is
## caught: no chip, a short freeze, the attacker recoils and the defender's
## counter attack fires. Later hits in the stance are blocked (mid pose).
@export var counter_guard_window_frames: int = 2
@export var counter_guard_stance_frames: int = 20
@export var counter_guard_freeze_frames: int = 6
@export var counter_guard_recoil_frames: int = 24

@export_group("Throws")
## Frames after a grab connects before the throw executes. The victim breaks
## it with a clean GUARD press (see guard_vanish_rearm_frames) inside this
## window or up to the same many frames before the grab, while facing the
## thrower; throws from behind can't be broken.
@export var throw_break_frames: int = 10
## The victim is held this far in front of the thrower.
@export var throw_hold_distance: float = 0.9
## Stick Y below -this at the press = throw behind you.
@export var throw_back_threshold: float = 0.5
## Break: both fighters slide apart at this speed and recoil this long.
@export var throw_break_push_speed: float = 6.0
@export var throw_break_recoil_frames: int = 16
## Thrower recovery after the throw executes.
@export var throw_recovery_frames: int = 24
## Third-party hit broke a throw or vanish battle (SPEC.md §4.5): frames of
## invulnerability the freed, un-hit participant gets as it recovers.
@export var lock_break_invuln_frames: int = 12

@export_group("Taunt")
## Taunt length; the ki reward is paid on its last frame (if not hit first).
@export var taunt_frames: int = 50
@export var taunt_ki_gain: float = 100.0
## Damage multiplier on a fighter hit while taunting.
@export var taunt_counter_damage_mult: float = 1.25

@export_group("Hit reactions")
@export var hitstop_light: int = 4
@export var hitstop_heavy: int = 8
## Longest a fighter stays lying on the ground (no input) before getting up.
@export var knockdown_frames: int = 40
## From this many frames lying, a button gets up at once (quick rise) and a
## dodge flick rolls (sway left/right, backflip back; up = quick rise).
@export var knockdown_min_frames: int = 8
## Airborne knockdown: from this frame after the last hit, a dodge flick
## flips back and lands on the feet (God Hand style air recovery).
@export var air_tech_min_frames: int = 18
@export var air_tech_back_speed: float = 5.0
@export var air_tech_lift: float = 4.0
@export var wakeup_invuln_frames: int = 20
## Length of the get-up (Wakeup) state; invuln may outlast it.
@export var wakeup_frames: int = 12
## Combo damage scaling (BT3-style): the first N hits of a combo deal full
## damage, then each further hit loses `combo_scaling_step`, down to the floor.
@export var combo_scaling_start_hit: int = 4
@export var combo_scaling_step: float = 0.03
@export var combo_scaling_min: float = 0.5
## Anti-loop: a melee move that already hit this combo segment (since the
## combo started or the attacker's last teleport) pushes the victim out into
## a knockdown instead of its normal reaction. So does a relaunch of an
## airborne victim beyond this many per segment.
@export var juggle_max_relaunches: int = 2
@export var loop_pushout_speed: float = 8.0

@export_group("Strikes")
## Stick Y beyond this picks the high (forward) / low (back) HEAVY variant;
## stick beyond this on any axis picks a directional charged smash on release.
@export var strike_dir_threshold: float = 0.5
## Upward speed of the bounce after a MoveData.ground_bounce hit.
@export var ground_bounce_velocity: float = 7.0

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
## Left stick past this (any direction) when vanishing or while vanished
## places the reappear point around the opponent from the teleporter's view:
## forward = behind them, sides = their flanks, back = in front of them.
## Neutral = behind their back.
@export var teleport_dir_threshold: float = 0.5
@export var teleport_frames: int = 8
## After reappearing, frames in which a follow-up attack still links.
@export var teleport_followup_window: int = 20
## Frames after one of your hits lands in which TELEPORT (or GUARD) teleports.
@export var teleport_hit_window: int = 30
## GUARD pressed at most this many frames before the first hit of a melee
## string lands vanishes (starts a vanish battle) instead of blocking, if ki
## allows. The window tightens as health drops (BT3: 4/3/2 frames at 30 Hz).
@export var guard_vanish_window: int = 8
@export var guard_vanish_window_hurt: int = 6
@export var guard_vanish_window_critical: int = 4
@export_range(0.0, 1.0) var guard_vanish_hurt_ratio: float = 0.7
@export_range(0.0, 1.0) var guard_vanish_critical_ratio: float = 0.3
## A GUARD press only opens the window if the previous one was at least this
## many frames earlier: mashing GUARD never vanishes.
@export var guard_vanish_rearm_frames: int = 60
@export var guard_vanish_cost_bars: float = 1.0
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
## HEAVY from neutral farther than this (m) from the opponent fires a ki blast.
@export var close_combat_range: float = 3.0
## Stick Y beyond this picks the forward (super2) / back (ultimate) SPECIAL.
@export var special_dir_threshold: float = 0.5
## Global freeze before the ultimate's startup (cinematic beat).
@export var ultimate_freeze_frames: int = 45
