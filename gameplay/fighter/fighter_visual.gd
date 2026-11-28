class_name FighterVisual
extends SmoothedVisual
## Humanoid posed in code: a rig of joint nodes rotated toward named POSES.
## The body is the low-poly model (FighterModel: one rigidly skinned mesh
## whose skeleton copies the rig every frame, toon shaded and outlined), or
## primitive meshes on the joints when the model is unavailable. A blob
## shadow sits under it. Strictly read-only on the Fighter (its parent):
## reads state/pose each frame and listens to its `event` signal for
## flashes. Never touches sim state. Follows the fighter with motion
## smoothing (SmoothedVisual).
##
## Animation: every joint (and the root offset) is a damped spring
## (PoseSprings, feel in Tuning.anim) chasing a target pose, so changes
## carry momentum, overshoot and settle instead of easing to a dead stop.
## Targets: a keyframed track on the move's own timeline for attacks that
## have one (MoveTracks), else the named POSES; idle breathing / weight
## shift are added to the target, walk swing and head follow-through on top.
## Hits taken kick the springs (hit reactions).
##
## Rotation convention: limbs hang along -Y; +X rotation swings a limb
## forward (toward -Z = toward the opponent); the torso and head point up,
## so +X tilts them BACK; torso +Y turns the chest left. Angles in degrees.

const JOINTS: Array[StringName] = [
	&"torso", &"chest", &"head", &"sh_l", &"el_l", &"wr_l", &"sh_r", &"el_r", &"wr_r",
	&"hip_l", &"kn_l", &"an_l", &"hip_r", &"kn_r", &"an_r", &"spin",
]
## Rig layout (m): the chest pivots CHEST_AT above the waist (torso joint),
## the head and shoulders hang off the chest, wrists WRIST_AT below the
## elbow, ankles ANKLE_AT below the knee. At zero chest/wrist/ankle angles
## this is the old single-torso rig exactly (head 0.68, shoulders 0.58 up).
const CHEST_AT := Vector3(0, 0.30, 0)
const HEAD_AT := Vector3(0, 0.38, 0)
const SHOULDER_AT := Vector3(0.29, 0.28, 0)
const UPPER_ARM := 0.32
const WRIST_AT := Vector3(0, -0.22, 0)
const HIP_AT := Vector3(0.12, 0, 0)
const THIGH := 0.46
const ANKLE_AT := Vector3(0, -0.42, 0)
## Spring channel of the body offset (POSES' "root").
const ROOT := &"root"
## States lying on / rising off the floor: no spring overshoot through it.
const GROUNDED_STATES: Array[StringName] = [&"knockdown", &"ko", &"downed", &"out", &"wakeup", &"revive"]
## Where a hit landed on the victim (Tuning.anim hit_head/low_height).
enum HitZone { HEAD, BODY, LOW }
## Hitstun pose per HitZone.
const HITSTUN_POSES: Array[StringName] = [&"hitstun", &"hitstun_body", &"hitstun_low"]
## States that breathe and shift their weight (Tuning.anim idle).
const IDLE_STATES: Array[StringName] = [&"idle", &"walk", &"guard"]
const FLASH_TIME := 0.12
const WALK_CYCLE_HZ := 2.2
## Charge strike glow: emission grows (and whitens) with the charge.
const CHARGE_GLOW_COLOR := Color(1.0, 0.7, 0.2)
const CHARGE_GLOW_FULL_COLOR := Color(1.0, 1.0, 0.85)
const CHARGE_GLOW_ENERGY := 1.6
## How far the belly sphere sits ahead of the torso, in belly radii.
const BELLY_FORWARD := 0.45
## Meta on meshes VfxManager.afterimage() must not copy (the blob shadow).
const NO_AFTERIMAGE := &"no_afterimage"

## Named poses: joint -> rotation (deg). "root" = body offset (m). Attacks
## are MoveTracks (KEY_POSES); these are states and the get-up strike.
## Missing joints fall back to &"idle".
const POSES := {
	&"idle": {
		&"torso": Vector3(-6, -12, 0), &"head": Vector3(4, 12, 0),
		&"sh_l": Vector3(45, 0, -10), &"el_l": Vector3(105, 0, 0),
		&"sh_r": Vector3(35, 0, 10), &"el_r": Vector3(115, 0, 0),
		&"hip_l": Vector3(15, 0, -5), &"kn_l": Vector3(-20, 0, 0),
		&"hip_r": Vector3(-12, 0, 5), &"kn_r": Vector3(-15, 0, 0),
		&"wr_l": Vector3.ZERO, &"wr_r": Vector3.ZERO,
		&"spin": Vector3.ZERO, &"root": Vector3(0, -0.04, 0),
	},
	# Get-up strike: pushes off the floor onto both hands, legs tucked...
	&"getup_kick_windup": {&"torso": Vector3(70, 0, 0), &"head": Vector3(-35, 0, 0),
		&"sh_l": Vector3(-40, 0, -15), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(-40, 0, 15), &"el_r": Vector3(10, 0, 0),
		&"hip_l": Vector3(110, 0, -10), &"kn_l": Vector3(-140, 0, 0),
		&"hip_r": Vector3(110, 0, 10), &"kn_r": Vector3(-140, 0, 0), &"root": Vector3(0, -0.5, 0)},
	# ...then, hands planted, one leg swings out straight and low (capoeira
	# style) while the body spins a full circle (procedural, GETUP_SPIN_DEG).
	&"getup_kick": {&"torso": Vector3(75, 0, -10), &"head": Vector3(-40, 0, 10),
		&"sh_l": Vector3(-45, 0, -10), &"el_l": Vector3(5, 0, 0),
		&"sh_r": Vector3(-45, 0, 10), &"el_r": Vector3(5, 0, 0),
		&"hip_l": Vector3(100, 0, -15), &"kn_l": Vector3(-135, 0, 0),
		&"hip_r": Vector3(10, 0, 80), &"kn_r": Vector3(0, 0, 0), &"root": Vector3(0, -0.5, 0)},
	# Duck low poses (DUCK_POSES, picked by Fighter.duck_variant()), after
	# God Hand's three: a forward hunch behind raised forearms...
	&"duck": {&"torso": Vector3(-50, 0, 0), &"head": Vector3(35, 0, 0),
		&"sh_l": Vector3(110, 0, -15), &"el_l": Vector3(120, 0, 0),
		&"sh_r": Vector3(100, 0, 15), &"el_r": Vector3(125, 0, 0),
		&"hip_l": Vector3(110, 0, 0), &"kn_l": Vector3(-140, 0, 0),
		&"hip_r": Vector3(100, 0, 0), &"kn_r": Vector3(-140, 0, 0), &"root": Vector3(0, -0.666, 0)},
	# ...a deep curl dropping the head and shoulders off to the left...
	&"duck_curl": {&"torso": Vector3(-55, 15, 25), &"head": Vector3(25, 0, 15),
		&"sh_l": Vector3(35, 0, -10), &"el_l": Vector3(135, 0, 0),
		&"sh_r": Vector3(95, 0, 25), &"el_r": Vector3(130, 0, 0),
		&"hip_l": Vector3(100, 0, -15), &"kn_l": Vector3(-145, 0, 0),
		&"hip_r": Vector3(115, 0, 10), &"kn_r": Vector3(-150, 0, 0), &"root": Vector3(0, -0.667, 0)},
	# ...and a drop onto wide-spread knees.
	&"duck_wide": {&"torso": Vector3(-45, 0, 0), &"head": Vector3(28, 0, 0),
		&"sh_l": Vector3(40, 0, -30), &"el_l": Vector3(100, 0, 0),
		&"sh_r": Vector3(40, 0, 30), &"el_r": Vector3(100, 0, 0),
		&"hip_l": Vector3(85, 0, -35), &"kn_l": Vector3(-150, 0, 0),
		&"hip_r": Vector3(85, 0, 35), &"kn_r": Vector3(-150, 0, 0), &"root": Vector3(0, -0.608, 0)},
	&"sway_l": {&"torso": Vector3(-5, 0, 30), &"head": Vector3(0, 0, 15), &"root": Vector3(0, -0.04, 0)},
	&"sway_r": {&"torso": Vector3(-5, 0, -30), &"head": Vector3(0, 0, -15), &"root": Vector3(0, -0.04, 0)},
	# Sway start (StateTracks): ducked further under, knees giving.
	&"sway_l_dip": {&"torso": Vector3(-10, 0, 42), &"head": Vector3(4, 0, 22),
		&"sh_l": Vector3(60, 0, -20), &"el_l": Vector3(120, 0, 0), &"sh_r": Vector3(55, 0, 25), &"el_r": Vector3(120, 0, 0),
		&"hip_l": Vector3(30, 0, -12), &"kn_l": Vector3(-45, 0, 0), &"hip_r": Vector3(5, 0, 12), &"kn_r": Vector3(-40, 0, 0),
		&"root": Vector3(0, -0.1, 0)},
	&"sway_r_dip": {&"torso": Vector3(-10, 0, -42), &"head": Vector3(4, 0, -22),
		&"sh_l": Vector3(55, 0, -25), &"el_l": Vector3(120, 0, 0), &"sh_r": Vector3(60, 0, 20), &"el_r": Vector3(120, 0, 0),
		&"hip_l": Vector3(30, 0, -12), &"kn_l": Vector3(-45, 0, 0), &"hip_r": Vector3(5, 0, 12), &"kn_r": Vector3(-40, 0, 0),
		&"root": Vector3(0, -0.1, 0)},
	# Backflip push-off and landing crouches (StateTracks).
	&"backflip_load": {&"torso": Vector3(-15, 0, 0), &"head": Vector3(8, 0, 0),
		&"sh_l": Vector3(-40, 0, -15), &"el_l": Vector3(30, 0, 0), &"sh_r": Vector3(-40, 0, 15), &"el_r": Vector3(30, 0, 0),
		&"hip_l": Vector3(45, 0, -5), &"kn_l": Vector3(-75, 0, 0), &"hip_r": Vector3(40, 0, 5), &"kn_r": Vector3(-70, 0, 0),
		&"root": Vector3(0, -0.187, 0)},
	&"backflip_land": {&"torso": Vector3(-20, 0, 0), &"head": Vector3(12, 0, 0),
		&"sh_l": Vector3(40, 0, -35), &"el_l": Vector3(60, 0, 0), &"sh_r": Vector3(40, 0, 35), &"el_r": Vector3(60, 0, 0),
		&"hip_l": Vector3(45, 0, -5), &"kn_l": Vector3(-75, 0, 0), &"hip_r": Vector3(40, 0, 5), &"kn_r": Vector3(-70, 0, 0),
		&"root": Vector3(0, -0.187, 0)},
	&"backflip": {&"hip_l": Vector3(100, 0, 0), &"kn_l": Vector3(-120, 0, 0), &"hip_r": Vector3(100, 0, 0),
		&"kn_r": Vector3(-120, 0, 0), &"sh_l": Vector3(150, 0, -20), &"sh_r": Vector3(150, 0, 20)},
	&"guard": {&"torso": Vector3(-12, 0, 0), &"sh_l": Vector3(80, 0, -30), &"el_l": Vector3(115, 0, 0),
		&"sh_r": Vector3(80, 0, 30), &"el_r": Vector3(115, 0, 0), &"head": Vector3(4, 0, 0)},
	&"guard_stun": {&"torso": Vector3(10, 0, 0), &"sh_l": Vector3(80, 0, -30), &"el_l": Vector3(115, 0, 0),
		&"sh_r": Vector3(80, 0, 30), &"el_r": Vector3(115, 0, 0)},
	&"guard_break": {&"torso": Vector3(25, 0, 0), &"head": Vector3(20, 0, 0), &"sh_l": Vector3(30, 0, -85),
		&"el_l": Vector3(20, 0, 0), &"sh_r": Vector3(30, 0, 85), &"el_r": Vector3(20, 0, 0)},
	&"charge": {&"torso": Vector3(6, 0, 0), &"head": Vector3(12, 0, 0), &"sh_l": Vector3(10, 0, -45),
		&"el_l": Vector3(30, 0, 0), &"sh_r": Vector3(10, 0, 45), &"el_r": Vector3(30, 0, 0),
		&"hip_l": Vector3(0, 0, -15), &"hip_r": Vector3(0, 0, 15), &"root": Vector3(0, -0.047, 0)},
	# Ki charge start (StateTracks): gathering in before powering up.
	&"charge_gather": {&"torso": Vector3(-20, 0, 0), &"head": Vector3(-8, 0, 0),
		&"sh_l": Vector3(55, 0, 20), &"el_l": Vector3(130, 0, 0), &"sh_r": Vector3(55, 0, -20), &"el_r": Vector3(130, 0, 0),
		&"hip_l": Vector3(20, 0, -12), &"kn_l": Vector3(-35, 0, 0), &"hip_r": Vector3(10, 0, 12), &"kn_r": Vector3(-35, 0, 0),
		&"root": Vector3(0, -0.067, 0)},
	# Hitstun by where the hit landed (FighterVisual hit zone): the head snaps
	# back, a body blow folds the chest over, a low hit buckles a knee.
	&"hitstun": {&"torso": Vector3(18, 0, 0), &"head": Vector3(20, 0, 0), &"sh_l": Vector3(-15, 0, -40),
		&"el_l": Vector3(30, 0, 0), &"sh_r": Vector3(-15, 0, 40), &"el_r": Vector3(30, 0, 0)},
	&"hitstun_body": {&"torso": Vector3(-32, 0, 0), &"head": Vector3(-6, 0, 0),
		&"sh_l": Vector3(35, 0, 10), &"el_l": Vector3(105, 0, 0), &"sh_r": Vector3(35, 0, -10), &"el_r": Vector3(105, 0, 0),
		&"hip_l": Vector3(25, 0, -5), &"kn_l": Vector3(-35, 0, 0), &"hip_r": Vector3(0, 0, 5), &"kn_r": Vector3(-30, 0, 0),
		&"root": Vector3(0, -0.072, 0.04)},
	&"hitstun_low": {&"torso": Vector3(-12, 0, -12), &"head": Vector3(10, 0, 8),
		&"sh_l": Vector3(20, 0, -45), &"el_l": Vector3(50, 0, 0), &"sh_r": Vector3(20, 0, 45), &"el_r": Vector3(50, 0, 0),
		&"hip_l": Vector3(55, 0, -8), &"kn_l": Vector3(-80, 0, 0), &"hip_r": Vector3(-10, 0, 8), &"kn_r": Vector3(-20, 0, 0),
		&"root": Vector3(0, -0.086, 0)},
	&"launched": {&"torso": Vector3(0, 0, 0), &"head": Vector3(15, 0, 0), &"hip_l": Vector3(30, 0, 0),
		&"hip_r": Vector3(15, 0, 0), &"sh_l": Vector3(60, 0, -60), &"sh_r": Vector3(60, 0, 60),
		&"spin": Vector3(40, 0, 0)},
	&"knockdown": {&"spin": Vector3(88, 0, 0), &"root": Vector3(0, -0.715, 0), &"torso": Vector3.ZERO,
		&"head": Vector3.ZERO, &"sh_l": Vector3(196, 0, -20),
		&"sh_r": Vector3(196, 0, 20), &"el_l": Vector3(0, 0, 0), &"el_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(-7, 0, -10), &"hip_r": Vector3(-7, 0, 10), &"kn_l": Vector3(0, 0, 0), &"kn_r": Vector3(0, 0, 0)},
	&"wakeup": {&"torso": Vector3(-30, 0, 0), &"hip_l": Vector3(90, 0, 0), &"kn_l": Vector3(-90, 0, 0),
		&"hip_r": Vector3(-45, 0, 0), &"kn_r": Vector3(-45, 0, 0), &"root": Vector3(0, -0.435, 0)},
	&"dash": {&"head": Vector3(20, 0, 0), &"torso": Vector3(-30, 0, 0), &"sh_l": Vector3(-45, 0, -10), &"sh_r": Vector3(-45, 0, 10),
		&"el_l": Vector3(30, 0, 0), &"el_r": Vector3(30, 0, 0)},
	# Dash startup (crouched push-off) and end lag (braking, leaning back).
	&"dash_start": {&"head": Vector3(12, 0, 0), &"torso": Vector3(-20, 0, 0), &"sh_l": Vector3(-20, 0, -15), &"sh_r": Vector3(-20, 0, 15),
		&"el_l": Vector3(45, 0, 0), &"el_r": Vector3(45, 0, 0), &"hip_l": Vector3(40, 0, 0),
		&"kn_l": Vector3(-60, 0, 0), &"hip_r": Vector3(-10, 0, 0), &"kn_r": Vector3(-30, 0, 0),
		&"root": Vector3(0, -0.134, 0)},
	&"dash_stop": {&"torso": Vector3(12, 0, 0), &"head": Vector3(-4, 0, 0), &"sh_l": Vector3(30, 0, -40),
		&"el_l": Vector3(20, 0, 0), &"sh_r": Vector3(30, 0, 40), &"el_r": Vector3(20, 0, 0),
		&"hip_l": Vector3(-30, 0, 0), &"kn_l": Vector3(-20, 0, 0), &"hip_r": Vector3(35, 0, 0),
		&"kn_r": Vector3(-50, 0, 0), &"root": Vector3(0, -0.126, 0)},
	# Ki charge release lag: exhaling, arms dropping out of the charge.
	&"charge_end": {&"torso": Vector3(-10, 0, 0), &"head": Vector3(-8, 0, 0), &"sh_l": Vector3(5, 0, -20),
		&"el_l": Vector3(20, 0, 0), &"sh_r": Vector3(5, 0, 20), &"el_r": Vector3(20, 0, 0),
		&"hip_l": Vector3(0, 0, -10), &"hip_r": Vector3(0, 0, 10), &"root": Vector3(0, -0.039, 0)},
	&"jump": {&"hip_l": Vector3(70, 0, 0), &"kn_l": Vector3(-100, 0, 0), &"hip_r": Vector3(40, 0, 0),
		&"kn_r": Vector3(-80, 0, 0)},
	&"vanish_wait": {&"head": Vector3(0, 40, 0), &"torso": Vector3(-5, 20, 0)},
	# --- guard poses (GUARD state; Fighter.GUARD_POSE_NAMES) -------------------
	&"guard_high": {&"torso": Vector3(-5, 0, 0), &"head": Vector3(10, 0, 0),
		&"sh_l": Vector3(150, 0, 18), &"el_l": Vector3(70, 0, 0),
		&"sh_r": Vector3(150, 0, -18), &"el_r": Vector3(70, 0, 0)},
	&"guard_low": {&"torso": Vector3(-30, 0, 0), &"head": Vector3(18, 0, 0),
		&"sh_l": Vector3(35, 0, 12), &"el_l": Vector3(45, 0, 0),
		&"sh_r": Vector3(35, 0, -12), &"el_r": Vector3(45, 0, 0),
		&"hip_l": Vector3(75, 0, -8), &"kn_l": Vector3(-105, 0, 0),
		&"hip_r": Vector3(40, 0, 8), &"kn_r": Vector3(-95, 0, 0), &"root": Vector3(0, -0.257, 0)},
	# Counter stance: leaning in, lead palm out to catch the hit.
	&"counter_guard": {&"torso": Vector3(-15, -20, 0), &"head": Vector3(10, 15, 0),
		&"sh_l": Vector3(95, 0, -10), &"el_l": Vector3(30, 0, 0),
		&"sh_r": Vector3(60, 0, 30), &"el_r": Vector3(120, 0, 0),
		&"hip_l": Vector3(35, 0, 0), &"kn_l": Vector3(-40, 0, 0), &"hip_r": Vector3(-20, 0, 0),
		&"root": Vector3(0, -0.113, 0)},
	# Pushed back off a guard / broken throw: rocked back, arms flung.
	&"recoil": {&"torso": Vector3(25, 0, 0), &"head": Vector3(12, 0, 0),
		&"sh_l": Vector3(-10, 0, -50), &"el_l": Vector3(40, 0, 0),
		&"sh_r": Vector3(-10, 0, 50), &"el_r": Vector3(40, 0, 0),
		&"hip_l": Vector3(25, 0, 0), &"kn_l": Vector3(-30, 0, 0), &"hip_r": Vector3(-25, 0, 0),
		&"root": Vector3(0, -0.073, 0)},
	# --- throws ----------------------------------------------------------------
	# THROW state: holding the victim (break window), then the toss.
	&"throw_hold": {&"torso": Vector3(-10, 0, 0), &"sh_l": Vector3(80, 0, 12), &"el_l": Vector3(50, 0, 0),
		&"sh_r": Vector3(80, 0, -12), &"el_r": Vector3(50, 0, 0),
		&"hip_l": Vector3(25, 0, 0), &"kn_l": Vector3(-30, 0, 0), &"hip_r": Vector3(-15, 0, 0), &"root": Vector3(0, -0.073, 0)},
	&"throw_toss": {&"torso": Vector3(25, -40, 0), &"head": Vector3(10, -10, 0),
		&"sh_l": Vector3(160, 0, -20), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(160, 0, 20), &"el_r": Vector3(10, 0, 0),
		&"hip_l": Vector3(-20, 0, 0), &"hip_r": Vector3(25, 0, 0), &"root": Vector3(0, 0.05, 0)},
	# Held by a thrower: lifted, limp.
	&"thrown": {&"torso": Vector3(15, 0, 10), &"head": Vector3(30, 0, 0),
		&"sh_l": Vector3(10, 0, -25), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(10, 0, 25), &"el_r": Vector3(15, 0, 0),
		&"hip_l": Vector3(10, 0, 0), &"kn_l": Vector3(-30, 0, 0),
		&"hip_r": Vector3(-5, 0, 0), &"kn_r": Vector3(-10, 0, 0), &"root": Vector3(0, 0.15, 0)},
	# Taunt: leaning back, hand on hip, beckoning (the wave is procedural).
	&"taunt": {&"torso": Vector3(10, -20, 0), &"head": Vector3(-10, 15, 0),
		&"sh_l": Vector3(15, 0, -40), &"el_l": Vector3(100, 0, 0),
		&"sh_r": Vector3(85, 0, 10), &"el_r": Vector3(70, 0, 0),
		&"hip_l": Vector3(5, 0, -10), &"hip_r": Vector3(-5, 0, 10)},
}
## Duck low pose per Fighter.duck_variant() (Fighter.DUCK_VARIANTS long).
const DUCK_POSES: Array[StringName] = [&"duck", &"duck_curl", &"duck_wide"]
## Taunt overlay: beckoning forearm wave and a cocky bob.
const TAUNT_WAVE_HZ := 2.5
const TAUNT_WAVE_DEG := 35.0
const TAUNT_BOB_HZ := 1.5
const TAUNT_BOB_HEIGHT := 0.03
## Get-up strike (pose &"getup_kick"): body turns this much over the
## move's active frames, so the extended leg sweeps all around.
const GETUP_SPIN_DEG := -360.0
## Held (thrown) fighters dangle a little.
const THROWN_SWAY_HZ := 3.0
const THROWN_SWAY_DEG := 8.0

var _fighter: Fighter
## Look to build when there is no Fighter parent (tests and tools); set
## before adding the visual to the tree. Ignored under a Fighter (its def).
var preview_def: CharacterDef
var _joints: Dictionary = {}  # StringName -> Node3D
## Joint angles (deg) and the root offset (m), sprung toward the target.
var _springs := PoseSprings.new()
## The current pose comes from a MoveTracks track (stiffer springs).
var _tracked := false
## Track clock: the attack's state frame at SmoothedVisual's blend point
## (f - 1 + fraction, so limbs stay in step with the drawn body); never
## runs backwards within a move, so it holds on frozen frames (hitstop,
## charge holds) instead of looping.
var _anim_frame := 0.0
var _anim_serial := -1
## StateTracks key being played (&"" when none).
var _state_key := &""
## The completed idle pose (springs fall back to it), built once in _build.
var _rest: Dictionary = {}
## Where the last hit taken landed (HitZone): picks the hitstun pose.
var _hit_zone := HitZone.HEAD
## Desyncs idle breathing between fighters (seconds).
var _idle_phase := 0.0
var _body: Node3D
## Glowing material: the model's toon material or the primitives' body colour.
var _mat: Material
## Rig nodes in creation order (parents first): the model's bones.
var _rig: Array[Node3D] = []
var _skeleton: Skeleton3D
var _shadow: MeshInstance3D
## Per fighter (its fade); the shader and mesh are shared.
var _shadow_mat: ShaderMaterial
var _shadow_fade := -1.0
static var _shadow_mesh: PlaneMesh
var _aura: KiAura
var _flash_left: float = 0.0
var _time: float = 0.0
## Seconds this fighter has been KO'd (co-op enemy fade-out).
var _ko_time: float = 0.0
var _fade: float = 0.0


func _ready() -> void:
	_fighter = get_parent() as Fighter
	_build()
	if _fighter:
		_fighter.event.connect(_on_event)


func _process(delta: float) -> void:
	super(delta)
	if _fighter == null:
		return
	_time += delta
	_body.visible = not _fighter.is_vanished()
	var a := Tuning.anim
	var pose := _with_idle_motion(complete_pose(_target_pose()))
	var st := _fighter.current_state_name()
	var hz := a.spring_hz
	var zeta := a.spring_damping
	if _tracked:
		hz = a.track_spring_hz
		zeta = a.track_spring_damping
	elif st in GROUNDED_STATES or _fighter.current_pose() == &"duck":
		zeta = a.grounded_spring_damping
	elif _fighter.attack_phase() == 1 or st == &"dodge":
		hz = a.strike_spring_hz
		zeta = a.strike_spring_damping
	_springs.step(pose, _rest, delta, hz, zeta, a.max_substep, a.max_substeps)
	for j in JOINTS:
		(_joints[j] as Node3D).rotation_degrees = _springs.value(j)
	_body.position = _springs.value(ROOT) * _body.scale.y
	_apply_head_lag()
	_apply_wrist_lag()
	_apply_procedural()
	if _skeleton != null:
		FighterModel.sync_pose(_skeleton, _rig)
	_update_shadow()
	_update_flash(delta)
	_aura.update(delta, _fighter.is_gaining_ki(), _fighter.ki >= _fighter.ki_max(), _body.visible)
	_update_ko_fade(delta)


func _target_pose() -> Dictionary:
	var f := _fighter
	var m0 := f.current_move()
	_tracked = m0 != null and MoveTracks.has_track(m0.pose)
	if _tracked:
		_state_key = &""
		return _track_pose(m0)
	_anim_serial = -1
	var id := f.current_pose()
	var skey := StateTracks.key_for(f.current_state_name(), id, f.dodge_kind())
	if skey != &"":
		_tracked = true
		return _state_track_pose(skey)
	_state_key = &""
	if f.attack_phase() == 0:
		var windup := StringName(String(id) + "_windup")
		if POSES.has(windup):
			id = windup
		else:
			return POSES[&"idle"]
	elif f.attack_phase() == 2 and f.current_move() != null:
		# Ease back to stance during the second half of recovery.
		var m := f.current_move()
		if f.state_frame() > m.startup + m.active + m.recovery / 2:
			return POSES[&"idle"]
	var pose_id := pose_id_for(id, f.current_state_name(), f.state_frame(), f.tuning, f.duck_variant())
	if pose_id == &"hitstun":
		pose_id = HITSTUN_POSES[_hit_zone]
	return POSES.get(pose_id, POSES[&"idle"])


## Target of a state with a StateTracks track, on the same kind of smoothed
## clock as the moves; it restarts on a new track or when the state starts
## over (sway into sway: the frame drops back).
func _state_track_pose(key: StringName) -> Dictionary:
	var f := float(_fighter.state_frame())
	var at := f - 1.0 + Engine.get_physics_interpolation_fraction() if SmoothedVisual.enabled else f
	if key != _state_key or at < _anim_frame - 1.0:
		_state_key = key
		_anim_frame = at
	_anim_frame = clampf(maxf(_anim_frame, at), f - 1.0, f)
	return StateTracks.sample(key, _anim_frame, _fighter.tuning, POSES[&"idle"])


## Target of a tracked move: its track sampled at the smoothed frame.
func _track_pose(m: MoveData) -> Dictionary:
	var f := float(_fighter.state_frame())
	var at := f - 1.0 + Engine.get_physics_interpolation_fraction() if SmoothedVisual.enabled else f
	var serial := _fighter.current_move_serial()
	if serial != _anim_serial:
		_anim_serial = serial
		_anim_frame = at
	# Clamped to the current tick so a frame moved back (rollback) is followed.
	_anim_frame = clampf(maxf(_anim_frame, at), f - 1.0, f)
	return MoveTracks.sample(m.pose, MoveTracks.timeline_u(m, _anim_frame), POSES[&"idle"])


## Idle life added to the target: breathing (chest, shoulders, a small bob)
## and a slow weight shift with the head kept level.
func _with_idle_motion(pose: Dictionary) -> Dictionary:
	if _fighter.current_state_name() not in IDLE_STATES:
		return pose
	var a := Tuning.anim
	var t := _time + _idle_phase
	var b := sin(t * TAU * a.breath_hz)
	var w := sin(t * TAU * a.weight_shift_hz)
	var out := pose.duplicate()
	var idle: Dictionary = POSES[&"idle"]
	out[&"torso"] = (pose.get(&"torso", idle[&"torso"]) as Vector3) + Vector3(b * a.breath_deg, 0, w * a.weight_shift_deg)
	out[&"head"] = (pose.get(&"head", idle[&"head"]) as Vector3) - Vector3(b * a.breath_deg, 0, w * a.weight_shift_deg)
	out[&"sh_l"] = (pose.get(&"sh_l", idle[&"sh_l"]) as Vector3) - Vector3(0, 0, b * a.breath_deg)
	out[&"sh_r"] = (pose.get(&"sh_r", idle[&"sh_r"]) as Vector3) + Vector3(0, 0, b * a.breath_deg)
	out[ROOT] = (pose.get(ROOT, idle[ROOT]) as Vector3) + Vector3(0, b * a.breath_bob, 0)
	return out


## Follow-through: the head trails the torso's turn (counter-rotates by the
## torso's sprung angular velocity), then catches up.
func _apply_head_lag() -> void:
	var a := Tuning.anim
	var lag := _springs.velocity(&"torso") * a.head_lag
	var m := a.head_lag_max_deg
	var head: Node3D = _joints[&"head"]
	head.rotation_degrees -= Vector3(clampf(lag.x, -m, m), clampf(lag.y, -m, m), clampf(lag.z, -m, m))


## `pose` with the joints it leaves out filled in (Tuning.anim "Rig"): the
## chest takes chest_twist_share of the torso twist (the waist keeps the
## rest), each ankle flattens its boot against the floor. Poses and tracks
## are written for the waist+chest as one torso; setting &"chest" or an
## ankle explicitly opts out. Every pose goes through this (the visual,
## tests and tools), so they all see the same body.
static func complete_pose(pose: Dictionary) -> Dictionary:
	var a := Tuning.anim
	var idle: Dictionary = POSES[&"idle"]
	var out := pose.duplicate()
	if not pose.has(&"chest"):
		var t: Vector3 = pose.get(&"torso", idle[&"torso"])
		# Only the twist: the chest pivot sits on the waist's vertical axis, so
		# splitting Y keeps the shoulders where the pose put them; splitting
		# pitch/roll would curve the spine instead.
		out[&"torso"] = Vector3(t.x, t.y * (1.0 - a.chest_twist_share), t.z)
		out[&"chest"] = Vector3(0, t.y * a.chest_twist_share, 0)
	for sfx in ["_l", "_r"]:
		var an := StringName("an" + sfx)
		if pose.has(an):
			continue
		var hip: Vector3 = pose.get(StringName("hip" + sfx), idle[StringName("hip" + sfx)])
		var kn: Vector3 = pose.get(StringName("kn" + sfx), idle[StringName("kn" + sfx)])
		out[an] = Vector3(clampf(-(hip.x + kn.x), -a.ankle_max_deg, a.ankle_max_deg), 0, 0)
	return out


## Every joint + root at rest (the completed idle pose): what a channel
## missing from a target falls back to.
static func rest_pose() -> Dictionary:
	return complete_pose(POSES[&"idle"])


## Snap straight to `pose` (completed; no springs, no overlays): tests and
## tools that measure or render a pose.
func snap_to_pose(pose: Dictionary) -> void:
	var full := complete_pose(pose)
	var rest := rest_pose()
	for j in JOINTS:
		(_joints[j] as Node3D).rotation_degrees = full.get(j, rest[j])
	# Scaled like _process does, so a character's body_scale snaps true.
	_body.position = (full.get(ROOT, rest[ROOT]) as Vector3) * _body.scale.y
	if _skeleton != null:
		FighterModel.sync_pose(_skeleton, _rig)


## Wrists trail the forearm's swing, then catch up (a snap at the end).
func _apply_wrist_lag() -> void:
	var a := Tuning.anim
	var m := a.wrist_lag_max_deg
	for sfx in ["_l", "_r"]:
		var lag := _springs.velocity(StringName("el" + sfx)) * a.wrist_lag
		var wr: Node3D = _joints[StringName("wr" + sfx)]
		wr.rotation_degrees -= Vector3(clampf(lag.x, -m, m), clampf(lag.y, -m, m), clampf(lag.z, -m, m))


## Maps a non-attack current_pose() to a POSES key (states sharing a name
## with a move pose, or with phases of their own).
static func pose_id_for(id: StringName, state_name: StringName, frame: int, tuning: FighterTuning,
		duck_variant := 0) -> StringName:
	match state_name:
		&"dodge":
			if id != &"duck":
				return id
			# Low until the duck can chain (GH: low +2..+10), then rise.
			if tuning != null and frame > tuning.duck_chain_from_frame:
				return &"idle"
			return DUCK_POSES[duck_variant % DUCK_POSES.size()]
		&"walk", &"teleport":
			return &"idle"  # teleporting fighters are hidden anyway
		&"entering":
			return &"idle"  # appears via the reappear effect
		&"downed", &"out":
			return &"knockdown"  # lying on the floor
		&"revive":
			return &"charge"  # crouched over the downed teammate, powering up
		&"dash":
			# Fighter.dash_phase() from the state frame: startup / travel / end lag.
			if tuning == null:
				return &"dash"
			if frame <= tuning.dash_startup_frames:
				return &"dash_start"
			return &"dash" if frame <= tuning.dash_startup_frames + tuning.dash_frames else &"dash_stop"
		&"throw":
			# Holding the victim through the break window, then the toss.
			var hold := tuning.throw_break_frames if tuning != null else 0
			return &"throw_hold" if frame < hold else &"throw_toss"
	return id


## Co-op: a KO'd enemy (KO is final, the director removes it after
## Tuning.coop.enemy_fade_frames) stays solid for ko_fade_delay_ratio of that
## time, then fades out. Downable teammates go DOWNED instead and never fade.
func _update_ko_fade(delta: float) -> void:
	var cfg := _fighter.director.config if _fighter.director != null else null
	var fading := cfg != null and cfg.mode == MatchConfig.Mode.COOP and _fighter.is_ko() \
			and not _fighter.downable
	_ko_time = _ko_time + delta if fading else 0.0
	var total := Tuning.coop.enemy_fade_frames / float(Tuning.match_rules.tick_rate)
	var delay := total * Tuning.vfx.ko_fade_delay_ratio
	var a := clampf((_ko_time - delay) / maxf(total - delay, 0.001), 0.0, 1.0) if fading else 0.0
	if is_equal_approx(a, _fade):
		return
	_fade = a
	for node in _body.find_children("*", "MeshInstance3D", true, false):
		(node as GeometryInstance3D).transparency = a


## 0 = solid .. 1 = fully faded (co-op KO fade).
func fade_amount() -> float:
	return _fade


## Overlays that aren't static poses: walk cycle, backflip spin/arc.
func _apply_procedural() -> void:
	var f := _fighter
	match f.current_state_name():
		&"walk":
			var a := Tuning.anim
			var c := sin(_time * TAU * WALK_CYCLE_HZ)
			var s := c * 25.0
			_add_rot(&"hip_l", s)
			_add_rot(&"hip_r", -s)
			_add_rot(&"kn_l", -maxf(-s, 0.0))
			_add_rot(&"kn_r", -maxf(s, 0.0))
			# Arms swing against the legs, the chest counter-twists, the body
			# dips at each footfall (twice per stride).
			_add_rot(&"sh_l", -c * a.walk_arm_swing_deg)
			_add_rot(&"sh_r", c * a.walk_arm_swing_deg)
			(_joints[&"torso"] as Node3D).rotation_degrees.y += c * a.walk_torso_twist_deg
			_body.position.y -= absf(c) * a.walk_bob * _body.scale.y
		&"dodge":
			if f.dodge_direction() == InputFrame.Dodge.BACK:
				var p := clampf(f.state_frame() / float(maxi(f.tuning.backflip_move_frames, 1)), 0.0, 1.0)
				var spin: Node3D = _joints[&"spin"]
				spin.rotation_degrees.x = 360.0 * p
				_body.position.y += sin(PI * p) * 0.8
		&"attack":
			var m := f.current_move()
			if m != null and m.pose == &"getup_kick" and f.attack_phase() == 1:
				var p := clampf((f.state_frame() - m.startup) / float(maxi(m.active, 1)), 0.0, 1.0)
				var spin: Node3D = _joints[&"spin"]
				spin.rotation_degrees.y = GETUP_SPIN_DEG * p
		&"charge":
			_body.position.x += sin(_time * 60.0) * 0.01
		&"taunt":
			_add_rot(&"el_r", sin(_time * TAU * TAUNT_WAVE_HZ) * TAUNT_WAVE_DEG)
			_body.position.y += absf(sin(_time * TAU * TAUNT_BOB_HZ)) * TAUNT_BOB_HEIGHT
		&"thrown":
			var s := sin(_time * TAU * THROWN_SWAY_HZ) * THROWN_SWAY_DEG
			_add_rot(&"hip_l", s)
			_add_rot(&"hip_r", -s)
			_add_rot(&"head", s * 0.5)


func _add_rot(j: StringName, deg_x: float) -> void:
	var n: Node3D = _joints[j]
	n.rotation_degrees.x += deg_x


func _update_flash(delta: float) -> void:
	if _flash_left > 0.0:
		_flash_left -= delta
		_set_glow(Color.WHITE, 2.0 * (_flash_left / FLASH_TIME))
	elif _fighter.is_charging_strike():
		var r := _fighter.charge_ratio()
		_set_glow(CHARGE_GLOW_COLOR.lerp(CHARGE_GLOW_FULL_COLOR, r), CHARGE_GLOW_ENERGY * r)
	else:
		var invuln := _fighter.is_invulnerable() and _fighter.current_state_name() != &"ko"
		_set_glow(Color(0.6, 0.8, 1.0), 0.4 if invuln else 0.0)


func _set_glow(color: Color, energy: float) -> void:
	if _mat is ShaderMaterial:
		FighterModel.set_glow(_mat, color, energy)
	elif _mat is StandardMaterial3D:
		var m := _mat as StandardMaterial3D
		m.emission = color
		m.emission_energy_multiplier = energy


## Blob shadow: on the floor under the drawn body, smaller and fainter as
## the fighter rises.
func _update_shadow() -> void:
	var v := Tuning.vfx
	var at := global_position
	var height := maxf(at.y, 0.0)
	var k := 1.0 / (1.0 + height * v.blob_shadow_height_falloff)
	_shadow.visible = _body.visible
	_shadow.global_position = Vector3(at.x, v.blob_shadow_lift, at.z)
	var r := v.blob_shadow_radius * maxf(_body.scale.x, _body.scale.z) * k
	_shadow.scale = Vector3(r, 1.0, r)
	# The shader writes ALPHA, so GeometryInstance3D.transparency wouldn't apply.
	var fade := maxf(1.0 - k, _fade)
	if not is_equal_approx(fade, _shadow_fade):
		_shadow_fade = fade
		_shadow_mat.set_shader_parameter(&"fade", fade)


func _on_event(kind: StringName, data: Dictionary) -> void:
	match kind:
		&"hit":
			if data.get("slot", -1) != _fighter.slot:
				return
			var blocked: bool = data.get("blocked", false)
			if not blocked:
				_flash_left = FLASH_TIME
			_hit_reaction(data.get("position", _fighter.global_position), data.get("heavy", false), blocked)
		&"ground_bounce":
			if data.get("slot", -1) == _fighter.slot:
				_bounce_reaction()


## Hit taken: kick the springs so the body snaps away from the blow and
## settles into the hitstun pose (a blocked hit just rocks the guard).
func _hit_reaction(at: Vector3, heavy: bool, blocked: bool) -> void:
	var a := Tuning.anim
	var local := _fighter.global_transform.affine_inverse() * at
	var height := local.y / maxf(_body.scale.y, 0.01)
	# The zone is set even in a rollback resim: a hit first found there (a
	# mispredicted remote attack) must still pick its hitstun pose.
	if not blocked:
		_hit_zone = HitZone.HEAD
		if height < a.hit_low_height:
			_hit_zone = HitZone.LOW
		elif height < a.hit_head_height:
			_hit_zone = HitZone.BODY
	# A resim re-emits the hit: kick once (springs accumulate).
	if _fighter.director != null and _fighter.director.resimulating:
		return
	var k := (a.hit_heavy_scale if heavy else 1.0) * (a.hit_blocked_scale if blocked else 1.0)
	var torso_scale := 1.0
	if not blocked and _hit_zone == HitZone.LOW:
		torso_scale = a.hit_low_torso_scale
	elif not blocked and _hit_zone == HitZone.BODY:
		torso_scale = a.hit_body_torso_scale
	# A blow on the right (+x) drives that shoulder back: chest turns right (-Y).
	var side := signf(local.x)
	_springs.kick(&"torso", Vector3(a.hit_torso_impulse * torso_scale, -side * a.hit_twist_impulse, 0) * k)
	_springs.kick(&"head", Vector3(a.hit_head_impulse, 0, 0) * k)
	_springs.kick(&"sh_l", Vector3(-a.hit_arm_impulse, 0, -a.hit_arm_impulse) * k)
	_springs.kick(&"sh_r", Vector3(-a.hit_arm_impulse, 0, a.hit_arm_impulse) * k)


## Knocked down and bouncing off the floor: the body and limbs flop.
func _bounce_reaction() -> void:
	if _fighter.director != null and _fighter.director.resimulating:
		return
	var a := Tuning.anim
	_springs.kick(&"torso", Vector3(-a.bounce_torso_impulse, 0, 0))
	_springs.kick(&"head", Vector3(a.bounce_torso_impulse, 0, 0))
	for j in [&"sh_l", &"sh_r", &"hip_l", &"hip_r"]:
		_springs.kick(j, Vector3(a.bounce_limb_impulse, 0, 0))
	for j in [&"kn_l", &"kn_r"]:
		_springs.kick(j, Vector3(-a.bounce_limb_impulse, 0, 0))


# --- construction -------------------------------------------------------------

func _build() -> void:
	var tint := Color.WHITE
	if _fighter:
		tint = _fighter.tint()
	elif preview_def != null:
		tint = preview_def.color
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	# Spin pivots around the hips so backflips/knockdowns rotate the whole body.
	_build_rig()
	var d: CharacterDef = _fighter.def if _fighter else preview_def
	var path := model_path_for(d)
	if FighterModel.available(path):
		_mat = FighterModel.make_material(tint)
		var extra := {}
		if d != null and d.belly_radius > 0.0:
			extra[&"belly"] = _belly_transform(d.belly_radius)
		_skeleton = FighterModel.create(path, _rig, extra, _mat)
	if _skeleton != null:
		_body.add_child(_skeleton)
	else:
		_build_primitives(tint, d)
	if d != null:
		_body.scale = d.body_scale
	_build_shadow()
	_aura = KiAura.new()
	add_child(_aura)
	_aura.setup(tint, _body.scale)
	_aura.visible = false

	_rest = rest_pose()
	var rest := _rest
	for j in JOINTS:
		_springs.reset(j, rest[j])
	_springs.reset(ROOT, rest[ROOT])
	_idle_phase = randf() / maxf(Tuning.anim.breath_hz, 0.01)


## The body model a character wears: its own when it loads, else the shared one.
static func model_path_for(d: CharacterDef) -> String:
	if d != null and FighterModel.available(d.model_path):
		return d.model_path
	return Tuning.vfx.fighter_model_path


## Joint nodes (no meshes): spin pivots around the hips so backflips and
## knockdowns rotate the whole body.
func _build_rig() -> void:
	var spin := _joint(&"spin", _body, Vector3(0, 0.95, 0))
	var hips := _node(&"hips", spin, Vector3(0, -0.95, 0))
	var pelvis := _node(&"pelvis", hips, Vector3(0, 0.95, 0))
	var torso := _joint(&"torso", pelvis, Vector3.ZERO)
	var chest := _joint(&"chest", torso, CHEST_AT)
	_joint(&"head", chest, HEAD_AT)
	for side in [-1.0, 1.0]:
		var sfx := "_l" if side < 0.0 else "_r"
		var sh := _joint(StringName("sh" + sfx), chest, Vector3(SHOULDER_AT.x * side, SHOULDER_AT.y, 0))
		var el := _joint(StringName("el" + sfx), sh, Vector3(0, -UPPER_ARM, 0))
		_joint(StringName("wr" + sfx), el, WRIST_AT)
	for side in [-1.0, 1.0]:
		var sfx := "_l" if side < 0.0 else "_r"
		var hip := _joint(StringName("hip" + sfx), pelvis, Vector3(HIP_AT.x * side, 0, 0))
		var kn := _joint(StringName("kn" + sfx), hip, Vector3(0, -THIGH, 0))
		_joint(StringName("an" + sfx), kn, ANKLE_AT)


func _belly_transform(radius: float) -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3.ONE * radius), Vector3(0, 0.2, -radius * BELLY_FORWARD))


## Placeholder body (no model): primitives on the rig's joints.
func _build_primitives(tint: Color, d: CharacterDef) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.6
	# Glow (hit flash, charge, invulnerable) is emission energy only: toggling
	# emission_enabled would swap the shader and recompile it (FxMaterials).
	mat.emission_enabled = true
	mat.emission_energy_multiplier = 0.0
	_mat = mat
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.93, 0.78, 0.65)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = tint.darkened(0.55)
	var torso: Node3D = _joints[&"torso"]
	_capsule(torso, Vector3(0, 0.18, 0), 0.2, 0.4, mat)
	_capsule(_joints[&"chest"], Vector3(0, 0.15, 0), 0.22, 0.45, mat)
	_sphere(_joints[&"head"], Vector3(0, 0.15, 0), 0.15, skin)
	if d != null and d.belly_radius > 0.0:
		_sphere(torso, Vector3(0, 0.2, -d.belly_radius * BELLY_FORWARD), d.belly_radius, mat)
	for sfx in ["_l", "_r"]:
		_capsule(_joints[StringName("sh" + sfx)], Vector3(0, -0.16, 0), 0.07, 0.34, mat)
		var el: Node3D = _joints[StringName("el" + sfx)]
		_capsule(el, Vector3(0, -0.12, 0), 0.06, 0.26, skin)
		_box(_joints[StringName("wr" + sfx)], Vector3(0, -0.10, 0), Vector3(0.13, 0.13, 0.13), dark)
		_capsule(_joints[StringName("hip" + sfx)], Vector3(0, -0.23, 0), 0.09, 0.48, dark)
		var kn: Node3D = _joints[StringName("kn" + sfx)]
		_capsule(kn, Vector3(0, -0.21, 0), 0.075, 0.44, dark)
		_box(_joints[StringName("an" + sfx)], Vector3(0, -0.04, -0.06), Vector3(0.12, 0.08, 0.24), mat)


func _build_shadow() -> void:
	var v := Tuning.vfx
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = preload("res://presentation/fighter/blob_shadow.gdshader")
	_shadow_mat.set_shader_parameter(&"opacity", v.blob_shadow_opacity)
	if _shadow_mesh == null:
		_shadow_mesh = PlaneMesh.new()
		_shadow_mesh.size = Vector2(2.0, 2.0)  # unit radius; scaled per frame
	_shadow = MeshInstance3D.new()
	_shadow.name = "BlobShadow"
	_shadow.mesh = _shadow_mesh
	_shadow.material_override = _shadow_mat
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow.top_level = true
	_shadow.set_meta(NO_AFTERIMAGE, true)
	add_child(_shadow)


func _joint(id: StringName, parent: Node3D, at: Vector3) -> Node3D:
	var n := _node(id, parent, at)
	_joints[id] = n
	return n


func _node(id: StringName, parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = String(id)
	n.position = at
	parent.add_child(n)
	_rig.append(n)
	return n


func _capsule(parent: Node3D, at: Vector3, radius: float, height: float, mat: Material) -> void:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	_mesh(parent, at, cm, mat)


func _sphere(parent: Node3D, at: Vector3, radius: float, mat: Material) -> void:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	_mesh(parent, at, sm, mat)


func _box(parent: Node3D, at: Vector3, size: Vector3, mat: Material) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	_mesh(parent, at, bm, mat)


func _mesh(parent: Node3D, at: Vector3, m: Mesh, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
