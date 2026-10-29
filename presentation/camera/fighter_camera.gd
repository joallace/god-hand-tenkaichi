class_name FighterCamera
extends Camera3D
## Lock-on camera for one fighter (Budokai Tenkaichi / God Hand style).
##
## Sits behind its fighter on the target->fighter line, raised and offset to
## the right shoulder, looking at a point between the fighters biased toward
## the target (fighter.target; none = a point ahead). Distance grows with
## separation. Yaw is smoothed and speed limited so cross-ups swing around
## instead of popping. Visual only: reads the fighters' drawn (motion-
## smoothed) transforms, never writes gameplay state.
##
## InputFrame.move is in fighter space (+Y = toward target), so keeping the
## camera behind the fighter makes "stick up" = "screen forward".
##
## Free roam (Fighter.is_free_roaming, TARGET held): God Hand camera, behind
## the fighter's own facing and looking ahead of it, whatever the target.
## The same yaw smoothing blends between the two framings.
##
## Effects API: add_trauma(), fov_punch(), play_ultimate_cinematic().

var fighter: Fighter
## True when this camera renders a half-width view (two-player split
## screen; fov_split). 2x2 grid cells keep the screen's aspect: false.
var split := false

var trauma := 0.0
var _yaw := 0.0
var _have_yaw := false
var _look := Vector3.ZERO
var _fov_offset := 0.0
var _ult_t := -1.0
var _ult_sign := 1.0
var _ult_user: Fighter
var _time := 0.0
var _noise := FastNoiseLite.new()


func setup(p_fighter: Fighter, p_split: bool) -> void:
	fighter = p_fighter
	split = p_split
	name = "FighterCamera%d" % (fighter.slot + 1)
	_noise.seed = 1000 + fighter.slot * 77
	_noise.frequency = 1.0
	var t := Tuning.camera
	near = t.near
	far = t.far
	fov = _base_fov()


func _ready() -> void:
	current = true
	snap()


func _base_fov() -> float:
	return Tuning.camera.fov_split if split else Tuning.camera.fov_single


# --- effects API ---------------------------------------------------------------

## Trauma in 0..1; shake strength is trauma^2.
func add_trauma(amount: float) -> void:
	trauma = clampf(trauma + amount, 0.0, 1.0)


## Kick the FOV by `degrees` (negative zooms in); recovers smoothly.
func fov_punch(degrees: float) -> void:
	_fov_offset = degrees


## Short orbit around `user` (the fighter starting an ultimate), blending
## out of and back into the normal lock-on framing.
func play_ultimate_cinematic(user: Fighter, clockwise: bool = true) -> void:
	_ult_user = user
	_ult_t = 0.0
	_ult_sign = 1.0 if clockwise else -1.0
	add_trauma(Tuning.camera.trauma_ultimate)


## Jump straight to the target framing (round start).
func snap() -> void:
	if not _valid():
		return
	_have_yaw = false
	var d := _desired(0.0)
	global_position = d[0]
	_look = d[1]
	_orient()


# --- per frame -----------------------------------------------------------------

func _valid() -> bool:
	return fighter != null and is_instance_valid(fighter) and fighter.is_inside_tree()


func _process(delta: float) -> void:
	if not _valid():
		return
	var t := Tuning.camera
	_time += delta
	if _ult_t >= 0.0:
		_ult_t += delta
		if _ult_t >= t.ultimate_duration:
			_ult_t = -1.0

	var d := _desired(delta)
	global_position = global_position.lerp(d[0], _damp(t.position_damping, delta))
	_look = _look.lerp(d[1], _damp(t.look_damping, delta))
	_orient()

	# FOV punch recovery.
	_fov_offset = lerpf(_fov_offset, 0.0, _damp(t.fov_recover_damping, delta))
	fov = clampf(_base_fov() + _fov_offset, 10.0, 150.0)

	# Trauma shake via lens offsets + roll (doesn't disturb the follow state).
	trauma = maxf(trauma - t.trauma_decay * delta, 0.0)
	var s := trauma * trauma
	if s > 0.0001:
		var k := _time * t.shake_frequency
		h_offset = t.shake_max_offset * s * _noise.get_noise_2d(k, 0.0)
		v_offset = t.shake_max_offset * s * _noise.get_noise_2d(0.0, k)
		rotate_object_local(Vector3.FORWARD, deg_to_rad(t.shake_max_roll_deg) * s * _noise.get_noise_2d(k, k))
	else:
		h_offset = 0.0
		v_offset = 0.0


static func _damp(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)


func _orient() -> void:
	var to := _look - global_position
	if to.length_squared() > 0.0001 and absf(to.normalized().dot(Vector3.UP)) < 0.99:
		look_at(_look, Vector3.UP)


## Returns [camera_position, look_point]. Updates the smoothed yaw.
func _desired(delta: float) -> Array:
	var t := Tuning.camera
	# Frame what is drawn (motion-smoothed visuals), not the raw sim tick.
	var mt := SmoothedVisual.render_transform_of(fighter)
	var me := mt.origin
	var opp := me + (-mt.basis.z) * 4.0
	if fighter.target != null and is_instance_valid(fighter.target):
		opp = SmoothedVisual.render_transform_of(fighter.target).origin
	var flat := Vector3(me.x - opp.x, 0.0, me.z - opp.z)
	var sep := flat.length()
	var free := fighter.is_free_roaming()
	if free:
		# "Behind me" = behind the facing; frame a point ahead of it.
		flat = Vector3(mt.basis.z.x, 0.0, mt.basis.z.z)
		opp = me - flat.normalized() * t.free_roam_look_ahead

	# Yaw of the "behind me" direction (target -> me, or the facing).
	if free or sep > 0.05:
		var target_yaw := atan2(flat.x, flat.z)
		if not _have_yaw or delta <= 0.0:
			_yaw = target_yaw
			_have_yaw = true
		else:
			var diff := angle_difference(_yaw, target_yaw)
			var step := diff * _damp(t.free_roam_yaw_damping if free else t.yaw_damping, delta)
			var max_step := deg_to_rad(t.max_yaw_speed_deg) * delta
			_yaw += clampf(step, -max_step, max_step)
	elif not _have_yaw:
		_yaw = atan2(mt.basis.z.x, mt.basis.z.z)
		_have_yaw = true

	var dist := clampf(t.base_distance + sep * t.distance_per_meter, t.min_distance, t.max_distance)
	var height := minf(t.base_height + sep * t.height_per_meter, t.max_height)
	if free:
		dist = t.free_roam_distance
		height = t.free_roam_height
	var yaw := _yaw
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3.UP.cross(back)  # screen-right when looking along -back
	var pos := me + back * dist + Vector3.UP * height + right * t.shoulder_offset

	# Keep inside a reasonable radius around the arena.
	var max_r := fighter.director.arena_radius + t.radius_margin
	var horiz := Vector2(pos.x, pos.z)
	if horiz.length() > max_r:
		horiz = horiz.limit_length(max_r)
		pos.x = horiz.x
		pos.z = horiz.y
	pos.y = maxf(pos.y, t.min_camera_height)

	var ahead := opp - me if free else ((opp - me) * t.look_bias).limit_length(t.max_look_ahead)
	var look := me + ahead + Vector3.UP * t.look_height

	if _ult_t >= 0.0 and _ult_user != null and is_instance_valid(_ult_user):
		var p := clampf(_ult_t / t.ultimate_duration, 0.0, 1.0)
		var w := minf(smoothstep(0.0, t.ultimate_blend, p), 1.0 - smoothstep(1.0 - t.ultimate_blend, 1.0, p))
		var ut := SmoothedVisual.render_transform_of(_ult_user)
		var u := ut.origin
		var ub := ut.basis.z
		var a := atan2(ub.x, ub.z) + deg_to_rad(t.ultimate_orbit_deg) * p * _ult_sign
		var cpos := u + Vector3(sin(a), 0.0, cos(a)) * t.ultimate_distance + Vector3.UP * t.ultimate_height
		var clook := u + Vector3.UP * t.ultimate_look_height
		pos = pos.lerp(cpos, w)
		look = look.lerp(clook, w)
	return [pos, look]
