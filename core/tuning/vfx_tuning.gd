class_name VfxTuning
extends Resource
## Visual effects (presentation only). Edit data/tuning/vfx.tres.
## Durations in seconds, sizes in meters.

@export_group("Hit sparks")
@export var hit_color: Color = Color(1.0, 0.8, 0.3)
@export var heavy_hit_color: Color = Color(1.0, 0.45, 0.1)
@export var blocked_color: Color = Color(0.35, 0.7, 1.0)
## Blocked hit taken with a ki guard (drains ki).
@export var ki_guard_color: Color = Color(0.4, 1.0, 0.95)
## Diameter (m) of a hit's flash sphere; the other parts scale from it.
@export var hit_flash_size: float = 0.7
@export var heavy_flash_size: float = 1.4
@export var hit_duration: float = 0.18
@export var heavy_duration: float = 0.28
## Debris chunks flying out of a hit: count, speed (m/s), width and length
## (m) at launch (they shrink as they fly), lifetime as a multiple of the
## hit duration (random in this range).
@export var spark_count_light: int = 6
@export var spark_count_heavy: int = 12
@export var spark_speed: float = 4.5
@export var spark_size: float = 0.09
@export var spark_length: float = 0.4
@export var spark_life: Vector2 = Vector2(1.2, 2.0)
## Burst shading: how directly a face must look at the camera to go
## white-hot (0..1; above 1 never). Debris uses spark_core.
@export var burst_core: float = 0.62
@export var spark_core: float = 0.9
## Opacity of the flash sphere (its white core is opaque).
@export var hit_flash_alpha: float = 0.85
## White-hot inner flash: size and life multiples of the flash.
@export var hit_core_scale: float = 0.45
@export var hit_core_life: float = 0.6
## Heavy hits: flat shock ring around the impact (size and life multiples).
@export var hit_ring_scale: float = 2.0
@export var hit_ring_life: float = 1.0
## Shock rings (heavy hits, bounces, KO...) are tori this flat (height / width).
@export var ring_squash: float = 0.5
## Hit bursts are drawn this many m toward the camera (same size on
## screen): out of the victim's body, still behind anyone in front of it.
@export var hit_pull: float = 0.6
## A victim hit again within this many seconds (beam / rush multi-hits)
## gets a smaller burst (hit_repeat_scale), not the whole one again.
@export var hit_repeat_window: float = 0.12
@export var hit_repeat_scale: float = 0.6
## Used when a hit event has no position: fighter origin + this height.
@export var fallback_hit_height: float = 1.2

@export_group("Dust")
## Dust puffs kicked up by ground rings, landings and dodges.
@export var dust_color: Color = Color(0.96, 0.92, 0.84, 0.9)
@export var dust_puff_count: int = 7
## Puff size (m) at spawn (random in this range), grown by dust_grow.
@export var dust_puff_size: Vector2 = Vector2(0.35, 0.6)
@export var dust_grow: float = 1.8
@export var dust_duration: float = 0.5
## Distance (m) a ring's puffs travel outward, as a multiple of the ring size.
@export var dust_spread: float = 0.45
## Puffs at the feet when a dodge starts on the ground.
@export var dodge_dust_count: int = 3
@export var dodge_dust_size: float = 0.35

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
## Zip streaks flying off a vanish / reappear: count, length (m), speed (m/s).
@export var teleport_streaks: int = 7
@export var teleport_streak_length: float = 1.1
@export var teleport_streak_speed: float = 9.0

@export_group("Guard break / KO / ultimate")
@export var guard_break_color: Color = Color(1.0, 0.6, 0.1)
@export var guard_break_size: float = 2.0
@export var guard_break_duration: float = 0.4
@export var ko_color: Color = Color(1.0, 0.6, 0.25)
@export var ko_size: float = 3.0
@export var ko_duration: float = 0.5
@export var ultimate_color: Color = Color(1.0, 0.9, 0.3)
@export var ultimate_size: float = 4.0
@export var ultimate_duration: float = 0.6
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

@export_group("Ki blasts")
## Ki energy (blasts, beams) = caster colour lightened by this.
@export var energy_lighten: float = 0.1
## Core / ragged shell radius as multiples of the blast's hitbox radius.
@export var blast_core_scale: float = 0.75
@export var blast_shell_scale: float = 1.35
## Comet tail behind the blast: length and width as multiples of the hitbox radius.
@export var blast_tail_length: float = 6.0
@export var blast_tail_width: float = 2.2
## Spinning glint over the blast (size multiple of the hitbox radius, rad/s).
@export var blast_flare_scale: float = 3.2
@export var blast_flare_spin: float = 7.0
## Shell flame: vertex wobble (m), noise frequency (1/m), stream speed (m/s).
@export var energy_wobble: float = 0.08
@export var energy_freq: float = 3.0
@export var energy_flow_speed: float = 6.0
## Muzzle flash where a blast leaves the hand (size m, duration s).
@export var muzzle_size: float = 0.9
@export var muzzle_duration: float = 0.18

@export_group("Beams")
## Core / outer flame radius as multiples of the beam radius.
@export var beam_core_scale: float = 0.55
@export var beam_shell_scale: float = 1.05
## Head ball radius as a multiple of the beam radius.
@export var beam_head_scale: float = 1.2
## Glints at the hands and the head (size multiple of the beam radius, rad/s).
@export var beam_flare_scale: float = 5.0
@export var beam_flare_spin: float = 5.0
## Beam flame stream speed (m/s) and wobble (multiple of the beam radius).
@export var beam_flow_speed: float = 14.0
@export var beam_wobble: float = 0.3

@export_group("Ki aura")
## Flame shell around a charging fighter (m, before body_scale): height,
## widest radius (at aura_waist of the height) and radius at the feet.
@export var aura_height: float = 2.5
@export var aura_radius: float = 0.78
@export var aura_base_radius: float = 0.55
@export_range(0.0, 1.0) var aura_waist: float = 0.32
## Aura tint = fighter colour lightened by this; alpha of the shell.
@export var aura_lighten: float = 0.08
@export var aura_alpha: float = 0.9
## Seconds to flare up when the charge starts and to die down after it.
@export var aura_ramp_in: float = 0.12
@export var aura_ramp_out: float = 0.25
## Overshoot of the flare-up (power peaks at 1 + this, then settles).
@export var aura_burst: float = 0.35
## Ki motes rising around the body, and the swirl ring on the ground (m).
@export var aura_mote_count: int = 22
@export var aura_swirl_size: float = 2.4
@export var aura_swirl_spin: float = 1.6
## Ring of dust at the feet when the charge flares up.
@export var aura_ignite_ring: float = 2.6

@export_group("Effect pools")
## Pooled effect sprites VfxManager creates at match start (grows on
## demand; a heavy hit takes 2 + spark_count_heavy, a shockwave 1 + dust_puff_count).
@export var fx_pool_prefill: int = 48

@export_group("Material warm-up")
## Frames FxMaterials.warm_up() draws every effect material at match start
## (compiles shaders/pipelines then instead of on the first hit).
@export var material_warmup_frames: int = 3
## Radius (m) of the warm-up meshes: sub-pixel, so they never show.
@export var material_warmup_radius: float = 0.001
## Size (m) of their custom AABB, so frustum culling never skips them.
@export var material_warmup_cull_size: float = 10000.0

@export_group("Fighter look")
## Low-poly model (tools/blender/build_fighter.py); empty or missing = the
## primitive placeholder body.
@export var fighter_model_path: String = "res://assets/models/fighter_brawler.glb"
## Fixed palette slots (FighterModel.Slot); PRIMARY comes from the fighter's
## colour and PRIMARY_DARK is that darkened by primary_dark_amount.
@export var primary_dark_amount: float = 0.45
@export var skin_color: Color = Color(0.93, 0.74, 0.58)
@export var cloth_color: Color = Color(0.16, 0.17, 0.24)
@export var trim_color: Color = Color(0.95, 0.93, 0.86)
@export var hair_color: Color = Color(0.09, 0.07, 0.1)
@export var gold_color: Color = Color(0.95, 0.72, 0.2)
@export var sole_color: Color = Color(0.22, 0.2, 0.2)
## Toon light: N.L above threshold = lit, below = shade_floor of the light;
## softness = half width of the step.
@export var toon_threshold: float = 0.15
@export var toon_softness: float = 0.03
@export var toon_shade_floor: float = 0.35
## Rim light added on silhouettes (fraction of the albedo).
@export var toon_rim_strength: float = 0.35
@export var toon_rim_power: float = 3.0
## Inverted-hull outline (m, before body_scale; 0 = off).
@export var outline_width: float = 0.014
@export var outline_color: Color = Color(0.05, 0.04, 0.08)
## Blob shadow under each fighter: radius (m) on the ground, opacity, and
## how it shrinks/fades with height (scale = 1 / (1 + height * falloff)).
@export var blob_shadow_radius: float = 0.55
@export var blob_shadow_opacity: float = 0.45
@export var blob_shadow_height_falloff: float = 0.35
## Lift above the floor (m) against z-fighting.
@export var blob_shadow_lift: float = 0.02
