class_name CoopTuning
extends Resource
## Co-op mode rules (SPEC.md). Edit data/tuning/coop.tres. Frames are sim
## ticks at 60 Hz. Starting picks, not playtested.

@export_group("Field")
## Max fighters on the field at once (humans + ally + enemies); the rest queue.
@export_range(2, 16) var field_cap: int = 8
## Frames a queued enemy waits after a field slot frees.
@export_range(0, 600) var refill_delay_frames: int = 45
## Frames a new enemy is intangible and can't attack after appearing.
@export_range(0, 300) var entry_frames: int = 30
## Frames a KO'd enemy lingers (KO pose, fade) before it is removed.
@export_range(0, 600) var enemy_fade_frames: int = 120
## Arena radius growth (m) per fighter on the field beyond two.
@export_range(0.0, 10.0) var arena_radius_per_extra_fighter: float = 1.5
## Distance (m) of the human team's start positions from the centre.
@export_range(0.0, 20.0) var human_spawn_radius: float = 2.0
## Enemies appear this far (m) inside the ring edge (beyond body radius).
@export_range(0.0, 10.0) var spawn_edge_inset: float = 1.0
## Angle (degrees) between enemies appearing on the same tick.
@export_range(0.0, 180.0) var spawn_spread_degrees: float = 25.0

@export_group("Attack tokens")
## Enemies that may be attacking one player in melee at the same time.
@export_range(0, 8) var melee_tokens_per_player: int = 2
## Enemies that may be firing ranged attacks (blasts, beams, supers) at one player.
@export_range(0, 8) var ranged_tokens_per_player: int = 1
## A token returns to the pool after this many frames even if unused.
@export_range(1, 1200) var token_timeout_frames: int = 180
## A granted token whose holder hasn't started the attack within this many
## frames goes back to the pool.
@export_range(1, 600) var token_unused_frames: int = 90
## A token request that isn't renewed within this many frames is dropped
## (its wait time starts over).
@export_range(1, 600) var token_request_frames: int = 60
## Experimental: enemies outside the target's (sim-computed) view cone can't
## start an attack.
@export var offscreen_attack_rule: bool = false
## Half-angle (degrees) of that view cone around the player's facing.
@export_range(0.0, 180.0) var offscreen_cone_half_angle: float = 70.0

@export_group("Downed & revive")
## Reviver must stay within this distance (m) of the downed teammate.
@export_range(0.0, 10.0) var revive_range: float = 2.0
## Frames of holding TAUNT to revive.
@export_range(1, 1200) var revive_frames: int = 120
## Health ratio a revived fighter returns with.
@export_range(0.0, 1.0) var revive_health_ratio: float = 0.3
## Frames downed before bleeding out (OUT until the next wave break / run end).
@export_range(1, 7200) var bleed_out_frames: int = 900

@export_group("Waves")
## Breather between waves.
@export_range(0, 1200) var wave_break_frames: int = 180
## Health ratio (of max) restored to every standing team-0 fighter on a break.
@export_range(0.0, 1.0) var wave_heal_ratio: float = 0.25
## Ki (bars) restored on a break.
@export_range(0.0, 5.0) var wave_ki_refill: float = 1.0
## Endless: enemies in wave n (0-based) = the setup's enemy count + n * growth,
## capped by max.
@export_range(0.0, 8.0) var endless_count_growth: float = 0.5
@export_range(1, 64) var endless_max_count: int = 12
## Endless: CPU level rises one step every this many waves (from enemy_level).
@export_range(1, 50) var endless_waves_per_level: int = 3

@export_group("Setup defaults")
@export var default_structure: CoopConfig.Structure = CoopConfig.Structure.BRAWL
@export_range(1, 64) var default_enemy_count: int = 4
@export_range(1, 50) var default_wave_count: int = 3
@export_range(1, 64) var max_enemy_count: int = 30
@export_range(1, 50) var max_wave_count: int = 20
