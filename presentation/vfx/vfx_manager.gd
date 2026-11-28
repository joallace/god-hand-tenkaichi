class_name VfxManager
extends Node3D
## Spawns short-lived, visual-only effects in the shared world in response to
## fighter events (via MatchEventHub). No gameplay state is touched. The ki
## charge aura (KiAura), ki blasts (KiBlastVisual) and beams (BeamVisual)
## draw themselves; this adds the bursts around them.
##
## Effects are pooled meshes on two shared shader materials, picked and
## animated through instance uniforms: 3D bursts (FxMaterials.Fx.BURST:
## cel-banded flash spheres and debris chunks that dissolve) and sprites
## (FxMaterials.Fx.SPRITE: rings lying flat in the world, dust puffs, zip
## streaks, glints). So an effect builds no node, material or tween (on the
## web build creating those cost ~2 ms per heavy hit) and compiles no shader:
## a finished one is hidden and goes back to the pool, which is prefilled at
## setup and grows on demand. _process moves, scales and ages them.
##
## Everything is depth tested; hit bursts are pulled Tuning.vfx.hit_pull
## toward the camera (fx_pull) so the victim's body doesn't swallow them,
## while a fighter standing in front (your own, with the camera behind you)
## still covers them.
##
## Handled events: &"hit" {position, heavy, blocked, attacker_slot},
## &"perfect_dodge", &"dodge", &"teleport" / &"vanish" / &"reappear"
## {position}, &"guard_break", &"ko", &"ultimate_start", &"push_off",
## &"counter_guard", &"throw", &"throw_break", &"ground_bounce",
## &"taunt_done", &"ki_blast", &"beam". Blocked hits are tinted by
## guard_result (ki guard). Co-op: &"entry" (enemy appears), &"downed",
## &"revived", &"lock_broken".

const Shape := FxMaterials.Shape
const Facing := FxMaterials.Facing

## How a pooled effect's 2D size maps onto its mesh's scale.
enum ScaleMode {
	QUAD,   ## sprite quad: (x, y, 1)
	ROUND,  ## sphere: (x, x, x)
	CHUNK,  ## debris box along its local -Z: (x, x, y)
	RING,   ## torus, squashed: (x, x * Tuning.vfx.ring_squash, x)
}

## One pooled effect mesh and its animation (Tween.interpolate_value curves).
class Fx:
	var mi: MeshInstance3D
	var scale_mode := ScaleMode.QUAD
	var t := 0.0
	var duration := 1.0
	var pos_from := Vector3.ZERO
	var pos_to := Vector3.ZERO
	var pos_trans := Tween.TRANS_LINEAR
	var pos_ease := Tween.EASE_IN_OUT
	## Quad size (m): x = width, y = height (length along fx_dir for AXIS).
	var size_from := Vector2.ONE
	var size_to := Vector2.ONE
	var size_trans := Tween.TRANS_LINEAR
	var size_ease := Tween.EASE_IN_OUT
	var color := Color.WHITE
	## Fraction of the life after which alpha fades out linearly (1 = never).
	var fade_from := 0.75

var hub: MatchEventHub
var _active: Array[Fx] = []
var _free: Array[Fx] = []
## Seconds of _process so far, and when each victim last got a hit burst.
var _clock := 0.0
var _last_hit: Dictionary = {}  # victim instance id -> _clock
var _ball: SphereMesh
var _chunk: BoxMesh
var _torus: TorusMesh


func _init() -> void:
	name = "Vfx"


func setup(p_hub: MatchEventHub) -> void:
	hub = p_hub
	hub.fighter_event.connect(_on_fighter_event)
	var v := Tuning.vfx
	_ball = SphereMesh.new()
	_ball.radius = 0.5
	_ball.height = 1.0
	_ball.radial_segments = 16
	_ball.rings = 8
	_chunk = BoxMesh.new()
	_torus = TorusMesh.new()
	_torus.inner_radius = 0.45
	_torus.outer_radius = 0.5
	_torus.rings = 32
	_torus.ring_segments = 6
	for i in v.fx_pool_prefill:
		_free.append(_new_fx())
	FxMaterials.warm_up(self)


func _process(delta: float) -> void:
	_clock += delta
	var i := 0
	while i < _active.size():
		var fx := _active[i]
		fx.t = minf(fx.t + delta, fx.duration)
		_apply(fx)
		if fx.t >= fx.duration:
			_release(fx)
			_active[i] = _active[_active.size() - 1]
			_active.pop_back()
		else:
			i += 1


## Effects currently playing (tests).
func active_count() -> int:
	return _active.size()


func _on_fighter_event(f: Fighter, kind: StringName, data: Dictionary) -> void:
	var v := Tuning.vfx
	var up := Vector3.UP * v.fallback_hit_height
	match kind:
		&"hit":
			var victim := hub.hit_victim(f, data)
			var pos := hub.event_position(victim, data, v.fallback_hit_height)
			var now := _clock
			var repeat := now - float(_last_hit.get(victim.get_instance_id(), -INF)) < v.hit_repeat_window
			_last_hit[victim.get_instance_id()] = now
			if repeat:
				var c := v.heavy_hit_color if data.get("heavy", false) else v.hit_color
				if data.get("blocked", false):
					c = v.blocked_color
				hit_spark(pos, c, v.hit_flash_size * v.hit_repeat_scale, v.hit_duration, v.spark_count_light / 2)
			elif data.get("blocked", false):
				var ki_guard: bool = data.get("guard_result", -1) == MoveData.GuardResult.KI_GUARD
				hit_spark(pos, v.ki_guard_color if ki_guard else v.blocked_color, v.hit_flash_size, v.hit_duration,
						v.spark_count_light)
			elif data.get("heavy", false):
				hit_spark(pos, v.heavy_hit_color, v.heavy_flash_size, v.heavy_duration, v.spark_count_heavy, true)
			else:
				hit_spark(pos, v.hit_color, v.hit_flash_size, v.hit_duration, v.spark_count_light)
		&"perfect_dodge":
			afterimage(f, hub.last_position(f))
			glint(hub.last_position(f) + up, v.afterimage_color, v.teleport_flash_size, v.afterimage_duration)
		&"dodge":
			if not f.is_airborne() and data.get("kind", &"") != &"air_tech":
				dust(f.global_position, v.dodge_dust_count, v.dodge_dust_size, v.dodge_dust_size)
		&"teleport", &"vanish", &"reappear":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP
			zip(p, v.teleport_color, v.teleport_flash_size, v.teleport_duration)
			if kind == &"vanish":
				ring(p, v.teleport_color, v.vanish_ring_size, v.teleport_duration * 1.5)
		&"guard_break":
			var p := f.global_position + up
			hit_spark(p, v.guard_break_color, v.guard_break_size * 0.5, v.guard_break_duration, v.spark_count_heavy, true)
			ring(p, v.guard_break_color, v.guard_break_size, v.guard_break_duration)
		&"push_off":
			var p := hub.event_position(f, data, 0.0) + up
			hit_spark(p, v.push_off_color, v.push_off_size * 0.5, v.push_off_duration, v.spark_count_heavy)
			ring(p, v.push_off_color, v.push_off_size, v.push_off_duration)
		&"counter_guard":
			var p := hub.event_position(f, data, 0.0) + up
			glint(p, v.counter_color, v.counter_size, v.counter_duration)
			ring(p, v.counter_color, v.counter_size * 1.5, v.counter_duration)
		&"throw":
			var p := hub.event_position(f, data, 0.0) + up
			flash(p, v.throw_color, v.throw_size, v.throw_duration, v.hit_pull)
		&"throw_break":
			var p := hub.event_position(f, data, 0.0) + up
			var thrower := _director_fighter(f, data.get("attacker_slot", -1))
			if thrower != null:
				p = p.lerp(thrower.global_position + up, 0.5)
			hit_spark(p, v.throw_break_color, v.throw_break_size * 0.5, v.throw_break_duration, v.spark_count_heavy)
			ring(p, v.throw_break_color, v.throw_break_size, v.throw_break_duration)
		&"ground_bounce":
			var p := hub.event_position(f, data, 0.0)
			p.y = 0.0
			shockwave(p, v.ground_bounce_color, v.ground_bounce_size, v.ground_bounce_duration)
		&"taunt_done":
			glint(f.global_position + up, v.taunt_ki_color, v.taunt_ki_size, v.taunt_ki_duration)
			ground_ring(f.global_position, v.taunt_ki_color, v.taunt_ki_size * 1.5, v.taunt_ki_duration)
		&"ko":
			var p := f.global_position + up
			hit_spark(p, v.ko_color, v.ko_size * 0.5, v.ko_duration, v.spark_count_heavy, true)
			shockwave(Vector3(f.global_position.x, 0.0, f.global_position.z), v.ground_bounce_color,
					v.ko_size, v.ko_duration)
		&"ultimate_start":
			var p := f.global_position + up
			ring(p, v.ultimate_color, v.ultimate_size, v.ultimate_duration)
			flash(p, v.ultimate_color, v.ultimate_size * 0.5, v.ultimate_duration * 0.6)
			ground_ring(f.global_position, v.ultimate_color, v.ultimate_size * 1.2, v.ultimate_duration)
		&"ki_blast":
			var p := hub.event_position(f, data, v.fallback_hit_height)
			glint(p, f.tint().lightened(v.aura_lighten), v.muzzle_size, v.muzzle_duration)
			ring(p, f.tint().lightened(v.aura_lighten), v.muzzle_size, v.muzzle_duration)
		&"beam":
			var p := f.global_position + up
			ring(p, f.tint().lightened(v.aura_lighten), v.muzzle_size * 2.0, v.muzzle_duration * 2.0)
			ground_ring(f.global_position, f.tint().lightened(v.aura_lighten), v.muzzle_size * 3.0,
					v.muzzle_duration * 2.5)
		&"entry":
			var feet := hub.event_position(f, data, 0.0)
			zip(feet + up, v.entry_color, v.entry_size, v.entry_duration)
			shockwave(Vector3(feet.x, 0.0, feet.z), v.entry_color, v.entry_size * 1.5, v.entry_duration)
		&"downed":
			var feet := hub.event_position(f, data, 0.0)
			shockwave(Vector3(feet.x, 0.0, feet.z), v.downed_color, v.downed_size, v.downed_duration)
		&"revived":
			glint(f.global_position + up, v.revive_color, v.revive_size, v.revive_duration)
			ground_ring(f.global_position, v.revive_color, v.revive_size, v.revive_duration)
		&"lock_broken":
			var p := hub.event_position(f, data, 0.0) + up
			hit_spark(p, v.lock_broken_color, v.lock_broken_size * 0.5, v.lock_broken_duration, v.spark_count_heavy)
			ring(p, v.lock_broken_color, v.lock_broken_size, v.lock_broken_duration)


# --- composed effects ----------------------------------------------------------

## Impact: a cel-banded flash sphere with a white-hot core and debris chunks
## flying out; `heavy` adds a shock ring around it.
func hit_spark(pos: Vector3, color: Color, size: float, duration: float, count: int, heavy: bool = false) -> void:
	var v := Tuning.vfx
	flash(pos, Color(color, v.hit_flash_alpha), size, duration, v.hit_pull)
	flash(pos, Color(1, 1, 1, 0.95), size * v.hit_core_scale, duration * v.hit_core_life, v.hit_pull)
	sparks(pos, color, count, duration)
	if heavy:
		ring(pos, color, size * v.hit_ring_scale, duration * v.hit_ring_life)


## `count` debris chunks flying outward from `pos`, shrinking as they go.
func sparks(pos: Vector3, color: Color, count: int, duration: float) -> void:
	var v := Tuning.vfx
	for i in count:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.5, 1), randf_range(-1, 1)).normalized()
		var d := duration * randf_range(v.spark_life.x, v.spark_life.y)
		var fx := burst(_chunk, ScaleMode.CHUNK, color, pos, Vector2(v.spark_size, v.spark_length),
				Vector2(v.spark_size * 0.15, v.spark_length * 0.4), d, v.hit_pull, dir)
		fx.mi.set_instance_shader_parameter(&"fx_core", v.spark_core)
		fx.pos_to = pos + dir * v.spark_speed * d
		fx.pos_trans = Tween.TRANS_CUBIC
		fx.pos_ease = Tween.EASE_OUT


## Expanding flash sphere that dissolves. `pull`: m toward the camera (fx_pull).
func flash(pos: Vector3, color: Color, size: float, duration: float, pull: float = 0.0) -> void:
	var fx := burst(_ball, ScaleMode.ROUND, color, pos, Vector2.ONE * size * 0.3, Vector2.ONE * size, duration, pull)
	fx.size_trans = Tween.TRANS_QUAD
	fx.size_ease = Tween.EASE_OUT
	fx.fade_from = 1.0


## Flat (horizontal) shock ring at `pos`, expanding: a squashed torus, so
## it keeps some thickness seen edge-on.
func ring(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := burst(_torus, ScaleMode.RING, color, pos, Vector2.ONE * size * 0.2, Vector2.ONE * size, duration)
	fx.size_trans = Tween.TRANS_EXPO
	fx.size_ease = Tween.EASE_OUT


## Ring lying on the floor at `feet` (y = 0 = the floor).
func ground_ring(feet: Vector3, color: Color, size: float, duration: float) -> void:
	ring(Vector3(feet.x, Tuning.vfx.ground_bounce_height, feet.z), color, size, duration)


## Ground impact: a ring on the floor and dust thrown outward.
func shockwave(feet: Vector3, color: Color, size: float, duration: float) -> void:
	var v := Tuning.vfx
	ground_ring(feet, color, size, duration)
	dust(feet, v.dust_puff_count, v.dust_puff_size.x, v.dust_puff_size.y, size * v.dust_spread)


## `count` dust puffs at `feet`, sized min..max, drifting out by `spread` m.
func dust(feet: Vector3, count: int, size_min: float, size_max: float, spread: float = 0.4) -> void:
	var v := Tuning.vfx
	var phase := randf() * TAU
	for i in count:
		var a := phase + TAU * i / maxf(count, 1)
		var out := Vector3(cos(a), 0.0, sin(a))
		var s := randf_range(size_min, size_max)
		var at := feet + out * s * 0.3 + Vector3.UP * s * 0.35
		var fx := sprite(Shape.PUFF, v.dust_color, at, Vector2.ONE * s, Vector2.ONE * s * v.dust_grow,
				v.dust_duration * randf_range(0.8, 1.2))
		fx.pos_to = at + out * spread + Vector3.UP * s * 0.3
		fx.pos_trans = Tween.TRANS_QUAD
		fx.pos_ease = Tween.EASE_OUT
		fx.size_trans = Tween.TRANS_QUAD
		fx.size_ease = Tween.EASE_OUT
		fx.fade_from = 1.0


## Spinning glint (ki flares, perfect dodges, counters).
func glint(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := sprite(Shape.FLARE, color, pos, Vector2.ONE * size, Vector2.ONE * size * 1.4, duration, Tuning.vfx.hit_pull)
	fx.mi.set_instance_shader_parameter(&"fx_spin", Tuning.vfx.blast_flare_spin)
	fx.size_trans = Tween.TRANS_BACK
	fx.size_ease = Tween.EASE_OUT


## Vanish / reappear: a flash that zips away in streaks.
func zip(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var v := Tuning.vfx
	flash(pos, color, size, duration)
	for i in v.teleport_streaks:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.3, 0.6), randf_range(-1, 1)).normalized()
		var start := pos + dir * size * 0.2
		var fx := sprite(Shape.STREAK, color.lightened(0.3), start, Vector2(v.spark_size * 1.5, v.teleport_streak_length),
				Vector2(v.spark_size * 0.4, v.teleport_streak_length * 0.3), duration * 1.2, 0.0, Facing.AXIS, dir)
		fx.pos_to = start + dir * v.teleport_streak_speed * duration
		fx.pos_trans = Tween.TRANS_EXPO
		fx.pos_ease = Tween.EASE_OUT


# --- primitives ----------------------------------------------------------------

## Fighter in `slot` of `f`'s match (read only), or null.
func _director_fighter(f: Fighter, slot: int) -> Fighter:
	if slot < 0 or f.director == null:
		return null
	return f.director.fighter_for_slot(slot)


func _new_fx() -> Fx:
	var fx := Fx.new()
	fx.mi = FxMaterials.sprite(Shape.RING, Color.WHITE, Facing.CAMERA)
	fx.mi.visible = false
	add_child(fx.mi)
	return fx


## A pooled sprite drawing `shape` at `pos` (VfxManager is at the world
## origin), sized `size_from` -> `size_to` (m) over `duration`. Linear
## unless the caller changes the curves on the returned Fx. `pull`: m
## toward the camera (fx_pull; Tuning.vfx.hit_pull for hit bursts).
func sprite(shape: FxMaterials.Shape, color: Color, pos: Vector3, size_from: Vector2, size_to: Vector2,
		duration: float, pull: float = 0.0, facing: FxMaterials.Facing = Facing.CAMERA,
		dir: Vector3 = Vector3.UP) -> Fx:
	var fx := _take(FxMaterials.quad(), FxMaterials.Fx.SPRITE, ScaleMode.QUAD, pull)
	var mi := fx.mi
	mi.set_instance_shader_parameter(&"fx_shape", shape)
	mi.set_instance_shader_parameter(&"fx_facing", facing)
	mi.set_instance_shader_parameter(&"fx_dir", dir)
	mi.set_instance_shader_parameter(&"fx_spin", 0.0)
	return _start(fx, color, pos, size_from, size_to, duration)


## A pooled 3D burst mesh (`mesh`: a sphere or a debris box) at `pos`,
## sized `size_from` -> `size_to` (see ScaleMode) over `duration`; a CHUNK
## points its length along `dir`.
func burst(mesh: Mesh, mode: ScaleMode, color: Color, pos: Vector3, size_from: Vector2, size_to: Vector2,
		duration: float, pull: float = 0.0, dir: Vector3 = Vector3.ZERO) -> Fx:
	var fx := _take(mesh, FxMaterials.Fx.BURST, mode, pull)
	if not dir.is_zero_approx():
		fx.mi.basis = Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.98 else Vector3.RIGHT)
	return _start(fx, color, pos, size_from, size_to, duration)


## A pooled mesh set up to draw `mesh` with the shared `material`.
func _take(mesh: Mesh, material: FxMaterials.Fx, mode: ScaleMode, pull: float) -> Fx:
	var fx: Fx = _free.pop_back() if not _free.is_empty() else _new_fx()
	var mi := fx.mi
	mi.mesh = mesh
	mi.material_override = FxMaterials.shared(material)
	mi.basis = Basis.IDENTITY
	mi.set_instance_shader_parameter(&"fx_seed", randf())
	mi.set_instance_shader_parameter(&"fx_pull", pull)
	mi.set_instance_shader_parameter(&"fx_core", Tuning.vfx.burst_core)
	fx.scale_mode = mode
	return fx


func _start(fx: Fx, color: Color, pos: Vector3, size_from: Vector2, size_to: Vector2, duration: float) -> Fx:
	var mi := fx.mi
	fx.t = 0.0
	fx.duration = maxf(duration, 0.001)
	fx.pos_from = pos
	fx.pos_to = pos
	fx.pos_trans = Tween.TRANS_LINEAR
	fx.size_from = size_from
	fx.size_to = size_to
	fx.size_trans = Tween.TRANS_LINEAR
	fx.color = color
	fx.fade_from = 0.75
	_apply(fx)
	mi.visible = true
	_active.append(fx)
	return fx


## Place, size and age `fx` for its current time.
func _apply(fx: Fx) -> void:
	var mi := fx.mi
	var k := fx.t / fx.duration
	mi.position = Tween.interpolate_value(fx.pos_from, fx.pos_to - fx.pos_from, fx.t, fx.duration,
			fx.pos_trans, fx.pos_ease)
	var s: Vector2 = Tween.interpolate_value(fx.size_from, fx.size_to - fx.size_from, fx.t, fx.duration,
			fx.size_trans, fx.size_ease)
	s = Vector2(maxf(s.x, 0.001), maxf(s.y, 0.001))
	match fx.scale_mode:
		ScaleMode.QUAD: mi.scale = Vector3(s.x, s.y, 1.0)
		ScaleMode.ROUND: mi.scale = Vector3(s.x, s.x, s.x)
		ScaleMode.CHUNK: mi.scale = Vector3(s.x, s.x, s.y)
		ScaleMode.RING: mi.scale = Vector3(s.x, s.x * Tuning.vfx.ring_squash, s.x)
	var c := fx.color
	if k > fx.fade_from:
		c.a *= 1.0 - (k - fx.fade_from) / maxf(1.0 - fx.fade_from, 0.001)
	mi.set_instance_shader_parameter(&"fx_color", c)
	mi.set_instance_shader_parameter(&"fx_progress", k)


func _release(fx: Fx) -> void:
	fx.mi.visible = false
	_free.append(fx)


## Translucent copy of the fighter's meshes, fading out.
func afterimage(f: Fighter, at: Vector3) -> void:
	var v := Tuning.vfx
	var ghost := Node3D.new()
	ghost.name = "Afterimage"
	add_child(ghost)
	var offset := at - f.global_position
	var mat := FxMaterials.make(FxMaterials.Kind.TRANSLUCENT, v.afterimage_color)
	var n := 0
	for node in f.find_children("*", "MeshInstance3D", true, false):
		var src := node as MeshInstance3D
		if src == null or not src.is_visible_in_tree() or src.mesh == null \
				or src.has_meta(FighterVisual.NO_AFTERIMAGE):
			continue
		var skel := src.get_parent() as Skeleton3D
		if skel != null and src.skin != null:
			# Skinned body: a frozen copy of its skeleton (current pose) + mesh.
			var copy := skel.duplicate() as Skeleton3D
			(copy.get_node(^"Body") as MeshInstance3D).material_override = mat
			ghost.add_child(copy)
			copy.global_transform = Transform3D(skel.global_basis, skel.global_position + offset)
			n += 1
			if n >= v.afterimage_max_meshes:
				break
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ghost.add_child(mi)
		mi.global_transform = Transform3D(src.global_basis, src.global_position + offset)
		n += 1
		if n >= v.afterimage_max_meshes:
			break
	if n == 0:
		flash(at + Vector3.UP, v.afterimage_color, 1.2, v.afterimage_duration)
		ghost.queue_free()
		return
	var tw := ghost.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, v.afterimage_duration)
	tw.tween_callback(ghost.queue_free)
