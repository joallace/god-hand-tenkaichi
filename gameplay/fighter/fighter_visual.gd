class_name FighterVisual
extends Node3D
## Placeholder humanoid built from primitive meshes, posed in code. Strictly
## read-only on the Fighter (its parent): reads state/pose each frame and
## listens to its `event` signal for flashes. Never touches sim state.
##
## Rotation convention: limbs hang along -Y; +X rotation swings a limb
## forward (toward -Z = toward the opponent). Angles in degrees.

const JOINTS: Array[StringName] = [
	&"torso", &"head", &"sh_l", &"el_l", &"sh_r", &"el_r",
	&"hip_l", &"kn_l", &"hip_r", &"kn_r", &"spin",
]
## Pose speeds (1/s) for the exponential lerp toward the target pose.
const BLEND_SPEED := 16.0
const BLEND_SPEED_FAST := 40.0
const FLASH_TIME := 0.12
const WALK_CYCLE_HZ := 2.2
## Charge strike glow: emission grows (and whitens) with the charge.
const CHARGE_GLOW_COLOR := Color(1.0, 0.7, 0.2)
const CHARGE_GLOW_FULL_COLOR := Color(1.0, 1.0, 0.85)
const CHARGE_GLOW_ENERGY := 1.6

## Named poses: joint -> rotation (deg). "root" = body offset (m).
## Missing joints fall back to &"idle".
const POSES := {
	&"idle": {
		&"torso": Vector3(5, -10, 0), &"head": Vector3(-5, 10, 0),
		&"sh_l": Vector3(45, 0, -10), &"el_l": Vector3(105, 0, 0),
		&"sh_r": Vector3(35, 0, 10), &"el_r": Vector3(115, 0, 0),
		&"hip_l": Vector3(15, 0, -5), &"kn_l": Vector3(-20, 0, 0),
		&"hip_r": Vector3(-12, 0, 5), &"kn_r": Vector3(-15, 0, 0),
		&"spin": Vector3.ZERO, &"root": Vector3(0, -0.04, 0),
	},
	&"jab": {&"torso": Vector3(5, 25, 0), &"sh_l": Vector3(90, 0, 0), &"el_l": Vector3(5, 0, 0)},
	&"jab2": {&"torso": Vector3(5, -30, 0), &"sh_r": Vector3(90, 0, 0), &"el_r": Vector3(5, 0, 0)},
	&"hook": {&"torso": Vector3(5, -50, 0), &"sh_r": Vector3(80, 0, 75), &"el_r": Vector3(85, 0, 0)},
	&"kick": {&"torso": Vector3(-15, 0, 0), &"hip_r": Vector3(100, 0, 0), &"kn_r": Vector3(-5, 0, 0),
		&"hip_l": Vector3(-5, 0, 0), &"kn_l": Vector3(-10, 0, 0)},
	&"kick_high": {&"torso": Vector3(-30, -10, 0), &"head": Vector3(15, 0, 0), &"hip_r": Vector3(150, 0, 0),
		&"kn_r": Vector3(-5, 0, 0), &"hip_l": Vector3(-10, 0, 0), &"kn_l": Vector3(-10, 0, 0),
		&"root": Vector3(0, 0.05, 0)},
	&"kick_high_windup": {&"torso": Vector3(10, 15, 0), &"hip_r": Vector3(70, 0, 0), &"kn_r": Vector3(-100, 0, 0),
		&"kn_l": Vector3(-25, 0, 0)},
	&"kick_mid": {&"torso": Vector3(-15, -25, 0), &"hip_r": Vector3(95, 0, -10), &"kn_r": Vector3(-5, 0, 0),
		&"hip_l": Vector3(-5, 0, 0), &"kn_l": Vector3(-15, 0, 0)},
	&"kick_mid_windup": {&"torso": Vector3(0, 25, 0), &"hip_r": Vector3(70, 0, 0), &"kn_r": Vector3(-115, 0, 0),
		&"kn_l": Vector3(-20, 0, 0)},
	&"kick_low": {&"torso": Vector3(35, -20, 0), &"hip_l": Vector3(100, 0, 0), &"kn_l": Vector3(-130, 0, 0),
		&"hip_r": Vector3(70, 0, -35), &"kn_r": Vector3(0, 0, 0), &"sh_l": Vector3(20, 0, -40),
		&"root": Vector3(0, -0.45, 0)},
	&"kick_low_windup": {&"torso": Vector3(30, 30, 0), &"hip_l": Vector3(90, 0, 0), &"kn_l": Vector3(-120, 0, 0),
		&"hip_r": Vector3(40, 0, 0), &"kn_r": Vector3(-70, 0, 0), &"root": Vector3(0, -0.35, 0)},
	&"charge_kick": {&"torso": Vector3(-20, -15, 0), &"hip_r": Vector3(110, 0, 0), &"kn_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(-5, 0, 0), &"kn_l": Vector3(-15, 0, 0), &"sh_l": Vector3(-30, 0, -20)},
	&"charge_kick_windup": {&"torso": Vector3(5, 45, 0), &"hip_r": Vector3(85, 0, 0), &"kn_r": Vector3(-140, 0, 0),
		&"kn_l": Vector3(-35, 0, 0), &"sh_l": Vector3(40, 0, -30), &"sh_r": Vector3(-30, 0, 30),
		&"root": Vector3(0, -0.1, 0)},
	&"heavy": {&"torso": Vector3(20, -35, 0), &"sh_r": Vector3(95, 0, 0), &"el_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(35, 0, 0), &"kn_l": Vector3(-35, 0, 0), &"hip_r": Vector3(-30, 0, 0)},
	&"heavy_windup": {&"torso": Vector3(-5, 40, 0), &"sh_r": Vector3(-20, 0, 20), &"el_r": Vector3(120, 0, 0)},
	&"finisher": {&"torso": Vector3(-20, -20, 0), &"sh_r": Vector3(165, 0, 0), &"el_r": Vector3(25, 0, 0),
		&"root": Vector3(0, 0.12, 0)},
	&"finisher_windup": {&"torso": Vector3(30, 20, 0), &"sh_r": Vector3(0, 0, 10), &"el_r": Vector3(130, 0, 0),
		&"root": Vector3(0, -0.2, 0), &"kn_l": Vector3(-50, 0, 0), &"hip_l": Vector3(40, 0, 0)},
	&"jump_kick": {&"torso": Vector3(-10, 0, 0), &"hip_r": Vector3(80, 0, 0), &"kn_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(-30, 0, 0), &"kn_l": Vector3(-95, 0, 0)},
	# Diving kick: tucked, then one leg stabbed down-forward, leaning back.
	&"dive_kick": {&"torso": Vector3(-20, 0, 0), &"hip_r": Vector3(40, 0, 0), &"kn_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(85, 0, 0), &"kn_l": Vector3(-115, 0, 0), &"sh_l": Vector3(-20, 0, -45),
		&"sh_r": Vector3(-20, 0, 45)},
	&"dive_kick_windup": {&"torso": Vector3(15, 0, 0), &"hip_l": Vector3(95, 0, 0), &"kn_l": Vector3(-125, 0, 0),
		&"hip_r": Vector3(100, 0, 0), &"kn_r": Vector3(-130, 0, 0)},
	# Duck kick: stays in the crouch and sweeps one leg out along the floor.
	&"duck_kick": {&"torso": Vector3(40, -20, 0), &"hip_l": Vector3(110, 0, 0), &"kn_l": Vector3(-140, 0, 0),
		&"hip_r": Vector3(80, 0, -25), &"kn_r": Vector3(0, 0, 0), &"sh_l": Vector3(25, 0, -40),
		&"root": Vector3(0, -0.5, 0)},
	&"duck_kick_windup": {&"torso": Vector3(45, 15, 0), &"hip_l": Vector3(110, 0, 0), &"kn_l": Vector3(-140, 0, 0),
		&"hip_r": Vector3(105, 0, 0), &"kn_r": Vector3(-145, 0, 0), &"root": Vector3(0, -0.5, 0)},
	&"dash_punch": {&"torso": Vector3(35, -15, 0), &"sh_r": Vector3(90, 0, 0), &"el_r": Vector3(0, 0, 0),
		&"sh_l": Vector3(-35, 0, -10), &"hip_l": Vector3(45, 0, 0), &"hip_r": Vector3(-35, 0, 0)},
	&"ki_blast": {&"torso": Vector3(0, -25, 0), &"sh_r": Vector3(90, 0, 0), &"el_r": Vector3(0, 0, 0)},
	&"beam": {&"torso": Vector3(0, 0, 0), &"sh_l": Vector3(88, 0, 12), &"el_l": Vector3(0, 0, 0),
		&"sh_r": Vector3(88, 0, -12), &"el_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(5, 0, -20), &"hip_r": Vector3(5, 0, 20), &"kn_l": Vector3(-25, 0, 0),
		&"kn_r": Vector3(-25, 0, 0), &"root": Vector3(0, -0.12, 0)},
	&"beam_windup": {&"torso": Vector3(0, 60, 0), &"sh_l": Vector3(-20, 0, -30), &"el_l": Vector3(100, 0, 0),
		&"sh_r": Vector3(-30, 0, 20), &"el_r": Vector3(100, 0, 0), &"root": Vector3(0, -0.15, 0)},
	&"duck": {&"torso": Vector3(45, 0, 0), &"hip_l": Vector3(110, 0, 0), &"kn_l": Vector3(-140, 0, 0),
		&"hip_r": Vector3(100, 0, 0), &"kn_r": Vector3(-140, 0, 0), &"root": Vector3(0, -0.5, 0)},
	&"sway_l": {&"torso": Vector3(5, 0, 30), &"head": Vector3(0, 0, 15), &"root": Vector3(0, -0.1, 0)},
	&"sway_r": {&"torso": Vector3(5, 0, -30), &"head": Vector3(0, 0, -15), &"root": Vector3(0, -0.1, 0)},
	&"backflip": {&"hip_l": Vector3(100, 0, 0), &"kn_l": Vector3(-120, 0, 0), &"hip_r": Vector3(100, 0, 0),
		&"kn_r": Vector3(-120, 0, 0), &"sh_l": Vector3(150, 0, -20), &"sh_r": Vector3(150, 0, 20)},
	&"guard": {&"torso": Vector3(12, 0, 0), &"sh_l": Vector3(80, 0, -30), &"el_l": Vector3(115, 0, 0),
		&"sh_r": Vector3(80, 0, 30), &"el_r": Vector3(115, 0, 0), &"head": Vector3(15, 0, 0)},
	&"guard_stun": {&"torso": Vector3(-8, 0, 0), &"sh_l": Vector3(80, 0, -30), &"el_l": Vector3(115, 0, 0),
		&"sh_r": Vector3(80, 0, 30), &"el_r": Vector3(115, 0, 0)},
	&"guard_break": {&"torso": Vector3(-25, 0, 0), &"head": Vector3(-25, 0, 0), &"sh_l": Vector3(30, 0, -85),
		&"el_l": Vector3(20, 0, 0), &"sh_r": Vector3(30, 0, 85), &"el_r": Vector3(20, 0, 0)},
	&"charge": {&"torso": Vector3(-12, 0, 0), &"head": Vector3(-15, 0, 0), &"sh_l": Vector3(10, 0, -45),
		&"el_l": Vector3(30, 0, 0), &"sh_r": Vector3(10, 0, 45), &"el_r": Vector3(30, 0, 0),
		&"hip_l": Vector3(0, 0, -15), &"hip_r": Vector3(0, 0, 15), &"root": Vector3(0, -0.08, 0)},
	&"hitstun": {&"torso": Vector3(-30, 0, 0), &"head": Vector3(-30, 0, 0), &"sh_l": Vector3(-15, 0, -40),
		&"el_l": Vector3(30, 0, 0), &"sh_r": Vector3(-15, 0, 40), &"el_r": Vector3(30, 0, 0)},
	&"launched": {&"torso": Vector3(-35, 0, 0), &"head": Vector3(-30, 0, 0), &"hip_l": Vector3(30, 0, 0),
		&"hip_r": Vector3(15, 0, 0), &"sh_l": Vector3(60, 0, -60), &"sh_r": Vector3(60, 0, 60),
		&"spin": Vector3(40, 0, 0)},
	&"knockdown": {&"spin": Vector3(88, 0, 0), &"root": Vector3(0, -0.73, 0), &"torso": Vector3.ZERO,
		&"head": Vector3.ZERO, &"sh_l": Vector3(196, 0, -20),
		&"sh_r": Vector3(196, 0, 20), &"el_l": Vector3(0, 0, 0), &"el_r": Vector3(0, 0, 0),
		&"hip_l": Vector3(-7, 0, -10), &"hip_r": Vector3(-7, 0, 10), &"kn_l": Vector3(0, 0, 0), &"kn_r": Vector3(0, 0, 0)},
	&"wakeup": {&"torso": Vector3(40, 0, 0), &"hip_l": Vector3(90, 0, 0), &"kn_l": Vector3(-90, 0, 0),
		&"hip_r": Vector3(-45, 0, 0), &"kn_r": Vector3(-45, 0, 0), &"root": Vector3(0, -0.45, 0)},
	&"dash": {&"torso": Vector3(30, 0, 0), &"sh_l": Vector3(-45, 0, -10), &"sh_r": Vector3(-45, 0, 10),
		&"el_l": Vector3(30, 0, 0), &"el_r": Vector3(30, 0, 0)},
	&"jump": {&"hip_l": Vector3(70, 0, 0), &"kn_l": Vector3(-100, 0, 0), &"hip_r": Vector3(40, 0, 0),
		&"kn_r": Vector3(-80, 0, 0)},
	&"vanish_wait": {&"head": Vector3(0, 40, 0), &"torso": Vector3(-5, 20, 0)},
	# --- guard poses (GUARD state; Fighter.GUARD_POSE_NAMES) -------------------
	&"guard_high": {&"torso": Vector3(-5, 0, 0), &"head": Vector3(10, 0, 0),
		&"sh_l": Vector3(150, 0, 18), &"el_l": Vector3(70, 0, 0),
		&"sh_r": Vector3(150, 0, -18), &"el_r": Vector3(70, 0, 0)},
	&"guard_low": {&"torso": Vector3(30, 0, 0), &"head": Vector3(-15, 0, 0),
		&"sh_l": Vector3(35, 0, 12), &"el_l": Vector3(45, 0, 0),
		&"sh_r": Vector3(35, 0, -12), &"el_r": Vector3(45, 0, 0),
		&"hip_l": Vector3(75, 0, -8), &"kn_l": Vector3(-105, 0, 0),
		&"hip_r": Vector3(40, 0, 8), &"kn_r": Vector3(-95, 0, 0), &"root": Vector3(0, -0.23, 0)},
	# Counter stance: leaning in, lead palm out to catch the hit.
	&"counter_guard": {&"torso": Vector3(15, -20, 0), &"head": Vector3(5, 15, 0),
		&"sh_l": Vector3(95, 0, -10), &"el_l": Vector3(30, 0, 0),
		&"sh_r": Vector3(60, 0, 30), &"el_r": Vector3(120, 0, 0),
		&"hip_l": Vector3(35, 0, 0), &"kn_l": Vector3(-40, 0, 0), &"hip_r": Vector3(-20, 0, 0),
		&"root": Vector3(0, -0.08, 0)},
	# Pushed back off a guard / broken throw: rocked back, arms flung.
	&"recoil": {&"torso": Vector3(-25, 0, 0), &"head": Vector3(-15, 0, 0),
		&"sh_l": Vector3(-10, 0, -50), &"el_l": Vector3(40, 0, 0),
		&"sh_r": Vector3(-10, 0, 50), &"el_r": Vector3(40, 0, 0),
		&"hip_l": Vector3(25, 0, 0), &"kn_l": Vector3(-30, 0, 0), &"hip_r": Vector3(-25, 0, 0),
		&"root": Vector3(0, -0.05, 0)},
	# --- throws ----------------------------------------------------------------
	&"throw": {&"torso": Vector3(25, 0, 0), &"sh_l": Vector3(95, 0, -15), &"el_l": Vector3(15, 0, 0),
		&"sh_r": Vector3(95, 0, 15), &"el_r": Vector3(15, 0, 0),
		&"hip_l": Vector3(35, 0, 0), &"kn_l": Vector3(-35, 0, 0), &"hip_r": Vector3(-25, 0, 0)},
	&"throw_windup": {&"torso": Vector3(5, 0, 0), &"sh_l": Vector3(50, 0, -40), &"el_l": Vector3(70, 0, 0),
		&"sh_r": Vector3(50, 0, 40), &"el_r": Vector3(70, 0, 0),
		&"kn_l": Vector3(-30, 0, 0), &"kn_r": Vector3(-30, 0, 0), &"root": Vector3(0, -0.05, 0)},
	# THROW state: holding the victim (break window), then the toss.
	&"throw_hold": {&"torso": Vector3(10, 0, 0), &"sh_l": Vector3(80, 0, 12), &"el_l": Vector3(50, 0, 0),
		&"sh_r": Vector3(80, 0, -12), &"el_r": Vector3(50, 0, 0),
		&"hip_l": Vector3(25, 0, 0), &"kn_l": Vector3(-30, 0, 0), &"hip_r": Vector3(-15, 0, 0)},
	&"throw_toss": {&"torso": Vector3(-25, -40, 0), &"head": Vector3(-10, -10, 0),
		&"sh_l": Vector3(160, 0, -20), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(160, 0, 20), &"el_r": Vector3(10, 0, 0),
		&"hip_l": Vector3(-20, 0, 0), &"hip_r": Vector3(25, 0, 0), &"root": Vector3(0, 0.05, 0)},
	# Held by a thrower: lifted, limp.
	&"thrown": {&"torso": Vector3(-20, 0, 10), &"head": Vector3(-35, 0, 0),
		&"sh_l": Vector3(10, 0, -25), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(10, 0, 25), &"el_r": Vector3(15, 0, 0),
		&"hip_l": Vector3(10, 0, 0), &"kn_l": Vector3(-30, 0, 0),
		&"hip_r": Vector3(-5, 0, 0), &"kn_r": Vector3(-10, 0, 0), &"root": Vector3(0, 0.15, 0)},
	# Taunt: leaning back, hand on hip, beckoning (the wave is procedural).
	&"taunt": {&"torso": Vector3(-10, -20, 0), &"head": Vector3(-10, 15, 0),
		&"sh_l": Vector3(15, 0, -40), &"el_l": Vector3(100, 0, 0),
		&"sh_r": Vector3(85, 0, 10), &"el_r": Vector3(70, 0, 0),
		&"hip_l": Vector3(5, 0, -10), &"hip_r": Vector3(-5, 0, 10)},
	# --- charged smash variants --------------------------------------------------
	&"uppercut": {&"torso": Vector3(-20, -25, 0), &"head": Vector3(-15, 0, 0),
		&"sh_r": Vector3(175, 0, 0), &"el_r": Vector3(20, 0, 0),
		&"sh_l": Vector3(20, 0, -30), &"el_l": Vector3(90, 0, 0),
		&"hip_l": Vector3(-10, 0, 0), &"hip_r": Vector3(15, 0, 0), &"kn_r": Vector3(-10, 0, 0),
		&"root": Vector3(0, 0.15, 0)},
	&"uppercut_windup": {&"torso": Vector3(35, 30, 0), &"sh_r": Vector3(-10, 0, 15), &"el_r": Vector3(110, 0, 0),
		&"hip_l": Vector3(60, 0, 0), &"kn_l": Vector3(-80, 0, 0),
		&"hip_r": Vector3(30, 0, 0), &"kn_r": Vector3(-60, 0, 0), &"root": Vector3(0, -0.1, 0)},
	# Double-fisted overhead hammer.
	&"hammer": {&"torso": Vector3(40, -10, 0), &"head": Vector3(10, 0, 0),
		&"sh_l": Vector3(45, 0, 12), &"el_l": Vector3(10, 0, 0),
		&"sh_r": Vector3(45, 0, -12), &"el_r": Vector3(10, 0, 0),
		&"hip_l": Vector3(45, 0, 0), &"kn_l": Vector3(-45, 0, 0), &"hip_r": Vector3(-25, 0, 0),
		&"root": Vector3(0, -0.11, 0)},
	&"hammer_windup": {&"torso": Vector3(-25, 0, 0), &"head": Vector3(-15, 0, 0),
		&"sh_l": Vector3(185, 0, 10), &"el_l": Vector3(30, 0, 0),
		&"sh_r": Vector3(185, 0, -10), &"el_r": Vector3(30, 0, 0), &"root": Vector3(0, 0.05, 0)},
	# Sideways back-fists (+torso Y turns the chest to the fighter's left).
	&"smash_left": {&"torso": Vector3(0, 45, 0), &"head": Vector3(0, -20, 0),
		&"sh_l": Vector3(90, 0, -60), &"el_l": Vector3(5, 0, 0),
		&"sh_r": Vector3(40, 0, 20), &"el_r": Vector3(110, 0, 0),
		&"hip_l": Vector3(20, 0, -15), &"kn_l": Vector3(-25, 0, 0)},
	&"smash_left_windup": {&"torso": Vector3(5, -40, 0), &"sh_l": Vector3(80, 0, 40), &"el_l": Vector3(120, 0, 0),
		&"kn_l": Vector3(-30, 0, 0), &"kn_r": Vector3(-30, 0, 0), &"root": Vector3(0, -0.05, 0)},
	&"smash_right": {&"torso": Vector3(0, -45, 0), &"head": Vector3(0, 20, 0),
		&"sh_r": Vector3(90, 0, 60), &"el_r": Vector3(5, 0, 0),
		&"sh_l": Vector3(40, 0, -20), &"el_l": Vector3(110, 0, 0),
		&"hip_r": Vector3(20, 0, 15), &"kn_r": Vector3(-25, 0, 0)},
	&"smash_right_windup": {&"torso": Vector3(5, 40, 0), &"sh_r": Vector3(80, 0, -40), &"el_r": Vector3(120, 0, 0),
		&"kn_l": Vector3(-30, 0, 0), &"kn_r": Vector3(-30, 0, 0), &"root": Vector3(0, -0.05, 0)},
}
## Taunt overlay: beckoning forearm wave and a cocky bob.
const TAUNT_WAVE_HZ := 2.5
const TAUNT_WAVE_DEG := 35.0
const TAUNT_BOB_HZ := 1.5
const TAUNT_BOB_HEIGHT := 0.03
## Held (thrown) fighters dangle a little.
const THROWN_SWAY_HZ := 3.0
const THROWN_SWAY_DEG := 8.0

var _fighter: Fighter
var _joints: Dictionary = {}  # StringName -> Node3D
var _current: Dictionary = {}  # StringName -> Vector3 (deg)
var _root_offset: Vector3 = Vector3.ZERO
var _body: Node3D
var _mat: StandardMaterial3D
var _aura: MeshInstance3D
var _flash_left: float = 0.0
var _time: float = 0.0
var _fx: Array[MeshInstance3D] = []


func _ready() -> void:
	_fighter = get_parent() as Fighter
	_build()
	if _fighter:
		_fighter.event.connect(_on_event)


func _process(delta: float) -> void:
	if _fighter == null:
		return
	_time += delta
	_body.visible = not _fighter.is_vanished()
	var pose := _target_pose()
	var fast := _fighter.attack_phase() == 1 or _fighter.current_state_name() == &"dodge"
	var k := 1.0 - exp(-(BLEND_SPEED_FAST if fast else BLEND_SPEED) * delta)
	for j in JOINTS:
		var target: Vector3 = pose.get(j, POSES[&"idle"][j])
		_current[j] = (_current[j] as Vector3).lerp(target, k)
		(_joints[j] as Node3D).rotation_degrees = _current[j]
	var root_target: Vector3 = pose.get(&"root", POSES[&"idle"][&"root"])
	_root_offset = _root_offset.lerp(root_target, k)
	_body.position = _root_offset
	_apply_procedural()
	_update_flash(delta)
	_update_aura()
	_update_fx(delta)


func _target_pose() -> Dictionary:
	var f := _fighter
	var id := f.current_pose()
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
	return POSES.get(pose_id_for(id, f.current_state_name(), f.state_frame(), f.tuning), POSES[&"idle"])


## Maps a non-attack current_pose() to a POSES key (states sharing a name
## with a move pose, or with phases of their own).
static func pose_id_for(id: StringName, state_name: StringName, frame: int, tuning: FighterTuning) -> StringName:
	match state_name:
		&"walk", &"teleport":
			return &"idle"  # teleporting fighters are hidden anyway
		&"entering":
			return &"idle"  # appears via the reappear effect
		&"downed", &"out":
			return &"knockdown"  # lying on the floor
		&"throw":
			# Holding the victim through the break window, then the toss.
			var hold := tuning.throw_break_frames if tuning != null else 0
			return &"throw_hold" if frame < hold else &"throw_toss"
	return id


## Overlays that aren't static poses: walk cycle, backflip spin/arc.
func _apply_procedural() -> void:
	var f := _fighter
	match f.current_state_name():
		&"walk":
			var s := sin(_time * TAU * WALK_CYCLE_HZ) * 25.0
			_add_rot(&"hip_l", s)
			_add_rot(&"hip_r", -s)
			_add_rot(&"kn_l", -maxf(-s, 0.0))
			_add_rot(&"kn_r", -maxf(s, 0.0))
		&"dodge":
			if f.dodge_direction() == InputFrame.Dodge.BACK:
				var p := clampf(f.state_frame() / float(maxi(f.tuning.backflip_move_frames, 1)), 0.0, 1.0)
				var spin: Node3D = _joints[&"spin"]
				spin.rotation_degrees.x = 360.0 * p
				_body.position.y += sin(PI * p) * 0.8
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
		_mat.emission_enabled = true
		_mat.emission = Color.WHITE
		_mat.emission_energy_multiplier = 2.0 * (_flash_left / FLASH_TIME)
	elif _fighter.is_charging_strike():
		var r := _fighter.charge_ratio()
		_mat.emission_enabled = true
		_mat.emission = CHARGE_GLOW_COLOR.lerp(CHARGE_GLOW_FULL_COLOR, r)
		_mat.emission_energy_multiplier = CHARGE_GLOW_ENERGY * r
	else:
		var invuln := _fighter.is_invulnerable() and _fighter.current_state_name() != &"ko"
		_mat.emission_enabled = invuln
		_mat.emission = Color(0.6, 0.8, 1.0)
		_mat.emission_energy_multiplier = 0.4


func _update_aura() -> void:
	var on := _fighter.current_state_name() == &"charge"
	_aura.visible = on and _body.visible
	if on:
		var s := 1.0 + sin(_time * 12.0) * 0.08
		_aura.scale = Vector3(s, s * 1.1, s)


func _on_event(kind: StringName, data: Dictionary) -> void:
	match kind:
		&"hit":
			if data.get("slot", -1) == _fighter.slot and not data.get("blocked", false):
				_flash_left = FLASH_TIME
		&"teleport", &"vanish", &"reappear":
			_spawn_flash(data.get("position", _fighter.global_position))


## Expanding sphere flash at a world position (vanish/reappear).
func _spawn_flash(at: Vector3) -> void:
	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	m.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.8)
	m.material_override = mat
	m.top_level = true
	add_child(m)
	m.global_position = at + Vector3.UP
	m.set_meta(&"life", FLASH_TIME * 2.0)
	_fx.append(m)


func _update_fx(delta: float) -> void:
	for m in _fx.duplicate():
		var life: float = m.get_meta(&"life") - delta
		m.set_meta(&"life", life)
		var t := 1.0 - life / (FLASH_TIME * 2.0)
		m.scale = Vector3.ONE * (0.5 + t * 1.5)
		(m.material_override as StandardMaterial3D).albedo_color.a = maxf(0.8 * (1.0 - t), 0.0)
		if life <= 0.0:
			_fx.erase(m)
			m.queue_free()


# --- construction -------------------------------------------------------------

func _build() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = _fighter.tint() if _fighter else Color.WHITE
	_mat.roughness = 0.6
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.93, 0.78, 0.65)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = (_fighter.tint() if _fighter else Color.GRAY).darkened(0.55)

	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	# Spin pivots around the hips so backflips/knockdowns rotate the whole body.
	var spin := _joint(&"spin", _body, Vector3(0, 0.95, 0))
	var hips := Node3D.new()
	hips.position = Vector3(0, -0.95, 0)
	spin.add_child(hips)
	var pelvis := Node3D.new()
	pelvis.position = Vector3(0, 0.95, 0)
	hips.add_child(pelvis)

	var torso := _joint(&"torso", pelvis, Vector3.ZERO)
	_capsule(torso, Vector3(0, 0.33, 0), 0.22, 0.7, _mat)
	var head := _joint(&"head", torso, Vector3(0, 0.68, 0))
	_sphere(head, Vector3(0, 0.15, 0), 0.15, skin)

	for side in [-1.0, 1.0]:
		var sfx := "_l" if side < 0.0 else "_r"
		var sh := _joint(StringName("sh" + sfx), torso, Vector3(0.29 * side, 0.58, 0))
		_capsule(sh, Vector3(0, -0.16, 0), 0.07, 0.34, _mat)
		var el := _joint(StringName("el" + sfx), sh, Vector3(0, -0.32, 0))
		_capsule(el, Vector3(0, -0.14, 0), 0.06, 0.3, skin)
		_box(el, Vector3(0, -0.32, 0), Vector3(0.13, 0.13, 0.13), dark)

		var hip := _joint(StringName("hip" + sfx), pelvis, Vector3(0.12 * side, 0, 0))
		_capsule(hip, Vector3(0, -0.23, 0), 0.09, 0.48, dark)
		var kn := _joint(StringName("kn" + sfx), hip, Vector3(0, -0.46, 0))
		_capsule(kn, Vector3(0, -0.22, 0), 0.075, 0.46, dark)
		_box(kn, Vector3(0, -0.46, -0.06), Vector3(0.12, 0.08, 0.24), _mat)

	_aura = MeshInstance3D.new()
	var aura_mesh := SphereMesh.new()
	aura_mesh.radius = 1.1
	aura_mesh.height = 2.4
	_aura.mesh = aura_mesh
	var aura_mat := StandardMaterial3D.new()
	aura_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	aura_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	aura_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	aura_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var c := _mat.albedo_color.lightened(0.5)
	aura_mat.albedo_color = Color(c, 0.35)
	_aura.material_override = aura_mat
	_aura.position = Vector3(0, 1.0, 0)
	_aura.visible = false
	add_child(_aura)

	for j in JOINTS:
		_current[j] = POSES[&"idle"][j]


func _joint(id: StringName, parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = String(id)
	n.position = at
	parent.add_child(n)
	_joints[id] = n
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
