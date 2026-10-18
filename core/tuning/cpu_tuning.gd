class_name CpuTuning
extends Resource
## CPU opponent difficulty (data/tuning/cpu.tres).
##
## Every Vector2 below is (weakest level, strongest level): level i of
## `level_names` uses lerp(x, y, i / (levels - 1)). Add or remove names to
## change how many levels the menus offer. Chances are 0..1, durations are sim
## frames (60/s), distances meters. The CPU never cheats: harder levels only
## react sooner, decide more often and pick better options.

@export var level_names: PackedStringArray = PackedStringArray([
	"Punching Bag", "Rookie", "Easy", "Normal", "Hard", "Expert", "Master", "God Hand",
])
## One-line description per level (shown on the join screen).
@export var level_blurbs: PackedStringArray = PackedStringArray([
	"Barely fights back. Learn the controls.",
	"Slow reactions, short combos.",
	"Blocks now and then, rarely punishes.",
	"Guards and dodges some attacks, finishes its strings.",
	"Quick reactions, punishes mistakes, uses ki.",
	"Perfect dodges often, teleports after launchers.",
	"Near-instant reactions, wins most vanish battles.",
	"Frame-perfect. Good luck.",
])
@export var default_level: int = 3

@export_group("Perception")
## Frames between an opponent action starting and the CPU noticing it.
@export var reaction_frames: Vector2 = Vector2(30, 5)
## Random extra frames added to each reaction (0..value).
@export var reaction_jitter_frames: Vector2 = Vector2(12, 2)
## Frames between neutral-game decisions (movement, attacks, charging).
@export var think_interval: Vector2 = Vector2(40, 6)

@export_group("Defense")
## Chance to respond at all to a noticed incoming attack.
@export var defend_chance: Vector2 = Vector2(0.08, 0.92)
## Of those responses, the share that are dodges (the rest guard).
@export var dodge_preference: Vector2 = Vector2(0.15, 0.7)
## Chance to pick the right dodge (duck highs, sway the rest) over a random one.
@export var smart_dodge_chance: Vector2 = Vector2(0.2, 0.95)
## Max frames a dodge is fired off the ideal perfect-dodge timing (either way).
@export var dodge_timing_error: Vector2 = Vector2(10, 0)
## Chance to tap guard just before a melee hit to vanish (needs the ki).
@export var guard_vanish_chance: Vector2 = Vector2(0.0, 0.35)
## Chance to vanish out of hitstun when it has the ki.
@export var vanish_escape_chance: Vector2 = Vector2(0.0, 0.45)
## Chance to answer each vanish-battle exchange (it still needs the reaction
## time to fit in the shrinking window).
@export var vanish_respond_chance: Vector2 = Vector2(0.05, 0.9)
## Chance to guard or sway an incoming ki blast / beam.
@export var projectile_defend_chance: Vector2 = Vector2(0.1, 0.9)
## Chance to flip back onto the feet when launched (air tech).
@export var air_tech_chance: Vector2 = Vector2(0.0, 0.85)
## Chance to get up early (quick rise or roll) instead of staying down.
@export var wakeup_option_chance: Vector2 = Vector2(0.1, 0.9)
## Of those early get-ups, the share that roll away.
@export var wakeup_roll_chance: Vector2 = Vector2(0.2, 0.6)
## Chance to read a guarded attack and hold the guard pose its guard results
## favour (low vs low kicks repels them, etc.); a miss keeps a mid guard.
@export var guard_pose_chance: Vector2 = Vector2(0.1, 0.95)
## Chance to try breaking a grab with a clean GUARD press (it still needs the
## reaction time to fit in throw_break_frames).
@export var throw_break_chance: Vector2 = Vector2(0.0, 0.8)
## Chance to counter guard (stick forward + LIGHT from a held guard) a
## noticed string opener. Negative = never: only the top levels try.
@export var counter_guard_chance: Vector2 = Vector2(-0.15, 0.12)
## Chance to mash out of a guard crash / stagger...
@export var stun_mash_chance: Vector2 = Vector2(0.1, 0.95)
## ...and frames between mash presses (2 = every other frame, the fastest).
@export var stun_mash_interval_frames: Vector2 = Vector2(12, 3)

@export_group("Offense")
## Neutral game: chance to press forward / attack rather than wait or guard.
@export var aggression: Vector2 = Vector2(0.2, 0.8)
## Chance to punish a staggered or recovering opponent.
@export var punish_chance: Vector2 = Vector2(0.1, 0.95)
## Chance, per link, to stop a combo that is hitting.
@export var combo_drop_chance: Vector2 = Vector2(0.55, 0.03)
## Max random lateness (frames) of combo inputs; late enough drops the link.
@export var link_error_frames: Vector2 = Vector2(14, 0)
## Chance to stop a string that whiffed or was blocked instead of mashing on.
@export var string_discipline: Vector2 = Vector2(0.0, 0.85)
## Chance to vary attacks: high/low heavies and charge strikes.
@export var mixup_chance: Vector2 = Vector2(0.1, 0.6)
## Chance to teleport after a landed finisher and keep the combo going.
@export var teleport_chase_chance: Vector2 = Vector2(0.0, 0.8)
## Chance to spend ki on a super when one is affordable and makes sense.
@export var special_chance: Vector2 = Vector2(0.1, 0.75)
## Close range vs an opponent seen guarding: chance to throw (beats guard).
@export var throw_chance: Vector2 = Vector2(0.05, 0.45)
## Close range vs a seen counter stance: chance to hold back (guard) rather
## than swing into it.
@export var counter_respect_chance: Vector2 = Vector2(0.0, 0.8)
## Chance a charged smash is released with the stick held (directional smash).
@export var smash_direction_chance: Vector2 = Vector2(0.0, 0.6)
## Chance per neutral decision to taunt when it looks safe (opponent knocked
## down or far). Stronger levels decide more often, so theirs is lower.
@export var taunt_chance: Vector2 = Vector2(0.03, 0.005)

@export_group("Ki")
## Chance to charge ki when the opponent is far enough away.
@export var charge_chance: Vector2 = Vector2(0.3, 0.7)
## Charges until this many bars are full.
@export var charge_target_bars: Vector2 = Vector2(2, 5)
## Chance to fire a ki blast at range instead of closing in.
@export var blast_chance: Vector2 = Vector2(0.15, 0.35)

@export_group("Spacing (all levels)")
## Charging is only considered with the opponent at least this far away.
@export var safe_charge_distance: float = 8.0
## Stop charging when the opponent gets this close.
@export var charge_abort_distance: float = 5.0
## Extra meters added to an attack's reach when judging threats / range.
@export var reach_margin: float = 0.4
## Beyond this the CPU closes in with a dash rather than walking.
@export var dash_distance: float = 5.0
## Frames spent strafing out of a beam's line after swaying it.
@export var beam_strafe_frames: int = 40
## Frames a ki blast may still need to arrive for the CPU to react to it.
@export var blast_look_ahead_frames: int = 30
## Hold LIGHT/HEAVY this many extra frames past the charge frame (scaled by
## a random 0.5..1) when going for a charge strike.
@export var charge_strike_hold_frames: int = 40
## Opponent ki ratio under which blocked strings go for a ki-guard crush.
@export_range(0.0, 1.0) var guard_crush_ratio: float = 0.5
## Taunting is considered with the opponent (not attacking) this far away.
@export var taunt_safe_distance: float = 10.0

@export_group("Option weights (all levels)")
## Neutral-game pick weights, each multiplied by the level's chance for it.
@export var charge_weight: float = 2.0
@export var beam_weight: float = 0.4
@export var ultimate_weight: float = 0.5
@export var rush_weight: float = 0.3
## Close range, not attacking: guard (the rest back off / sidestep).
@export_range(0.0, 1.0) var close_guard_share: float = 0.5
## Close range mixups: charge strikes (the rest are directional heavies).
@export_range(0.0, 1.0) var charge_strike_share: float = 0.35
## Close range vs a guarding opponent: charge strike (the rest low kicks).
@export_range(0.0, 1.0) var guard_crush_charge_share: float = 0.5
## Close range: share of successful special rolls that throw out a rush.
@export_range(0.0, 1.0) var close_rush_share: float = 0.25
## Landed strings: share of successful special rolls that super cancel...
@export_range(0.0, 1.0) var super_cancel_share: float = 0.5
## ...and of those, the share that are rushes (the rest beams).
@export_range(0.0, 1.0) var super_cancel_rush_share: float = 0.6
## Throws: share thrown behind (stick back) instead of forward.
@export_range(0.0, 1.0) var back_throw_share: float = 0.3
## Teleport chases: share reappearing at a flank instead of behind.
@export_range(0.0, 1.0) var teleport_flank_share: float = 0.3
## Max sideways stick while walking in.
@export_range(0.0, 1.0) var approach_strafe: float = 0.4
## Random +- frames on every think interval (keeps it from feeling metronomic).
@export var think_jitter_frames: int = 2
## Random +- LIGHT presses on the string length a level aims for.
@export var string_length_jitter: int = 1
## Extra frames guard stays up after an expected hit.
@export var guard_tail_frames: int = 4
## Shortest charge strike hold, as a share of charge_strike_hold_frames.
@export_range(0.0, 1.0) var charge_strike_min_share: float = 0.5
## A dash attack is pressed when the gap left is this share of its reach.
@export_range(0.0, 1.0) var dash_attack_reach_share: float = 0.7


func level_count() -> int:
	return maxi(level_names.size(), 1)


func clamp_level(level: int) -> int:
	return clampi(level if level >= 0 else default_level, 0, level_count() - 1)


## 0 (weakest) .. 1 (strongest) for a level index.
func level_skill(level: int) -> float:
	var n := level_count()
	return 0.0 if n <= 1 else clamp_level(level) / float(n - 1)


func level_name(level: int) -> String:
	var i := clamp_level(level)
	return level_names[i] if i < level_names.size() else "Level %d" % (i + 1)


func level_blurb(level: int) -> String:
	var i := clamp_level(level)
	return level_blurbs[i] if i < level_blurbs.size() else ""
