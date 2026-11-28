class_name VfxManager
extends Node3D
## Spawns short-lived, visual-only effects in the shared world in response to
## fighter events (via MatchEventHub). No gameplay state is touched. The ki
## charge aura (KiAura), ki blasts (KiBlastVisual) and beams (BeamVisual)
## draw themselves; this adds the bursts around them.
##
## Every effect here is built from sprites: pooled 1x1 quads on one shared
## shader material (FxMaterials.Fx.SPRITE / SPRITE_ON_TOP) that draw a
## cel-shaded shape (FxMaterials.Shape: impact star, shock ring, flash orb,
## spark streak, dust puff, speed lines, glint) picked and animated through
## instance uniforms. So an effect builds no node, material or tween (on the
## web build creating those cost ~2 ms per heavy hit) and compiles no shader:
## a finished sprite is hidden and goes back to its pool, the pools are
## prefilled at setup and grow on demand. _process moves, scales and ages them.
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

## One pooled sprite and its animation (Tween.interpolate_value curves).
class Fx:
	var mi: MeshInstance3D
	var on_top: bool
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
var _free: Array[Fx] = []  # depth tested
var _free_on_top: Array[Fx] = []
## Seconds of _process so far, and when each victim last got a hit burst.
var _clock := 0.0
var _last_hit: Dictionary = {}  # victim instance id -> _clock
## Ground ring orientation: the quad (facing +Z) laid flat, facing up.
var _flat := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))


func _init() -> void:
	name = "Vfx"


func setup(p_hub: MatchEventHub) -> void:
	hub = p_hub
	hub.fighter_event.connect(_on_fighter_event)
	var v := Tuning.vfx
	for i in v.fx_pool_prefill:
		_free.append(_new_fx(false))
	for i in v.fx_pool_prefill_on_top:
		_free_on_top.append(_new_fx(true))
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
				star(pos, c, v.hit_flash_size * v.hit_repeat_scale, v.hit_duration)
				sparks(pos, c.lightened(0.35), v.spark_count_light / 2, v.hit_duration)
			elif data.get("blocked", false):
				var ki_guard: bool = data.get("guard_result", -1) == MoveData.GuardResult.KI_GUARD
				guard_spark(pos, v.ki_guard_color if ki_guard else v.blocked_color, v.hit_flash_size, v.hit_duration)
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
			guard_spark(p, v.push_off_color, v.push_off_size * 0.5, v.push_off_duration)
			ring(p, v.push_off_color, v.push_off_size, v.push_off_duration)
		&"counter_guard":
			var p := hub.event_position(f, data, 0.0) + up
			glint(p, v.counter_color, v.counter_size, v.counter_duration)
			ring(p, v.counter_color, v.counter_size * 1.5, v.counter_duration)
		&"throw":
			var p := hub.event_position(f, data, 0.0) + up
			flash(p, v.throw_color, v.throw_size, v.throw_duration, true)
			star(p, v.throw_color, v.throw_size, v.throw_duration)
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
			speedlines(p, v.ultimate_color, v.ultimate_size * 1.5, v.ultimate_duration)
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

## Impact: spiky star, white core flash, shock ring and spark streaks;
## `heavy` adds speed lines.
func hit_spark(pos: Vector3, color: Color, size: float, duration: float, count: int, heavy: bool = false) -> void:
	var v := Tuning.vfx
	star(pos, color, size, duration)
	flash(pos, Color(1, 1, 1, 0.95), size * v.core_flash_scale, duration * v.core_flash_life, true)
	var r := sprite(Shape.RING, color, pos, Vector2.ONE * size * v.hit_ring_scale.x,
			Vector2.ONE * size * v.hit_ring_scale.y, duration * v.hit_ring_life, true)
	r.size_trans = Tween.TRANS_EXPO
	r.size_ease = Tween.EASE_OUT
	if heavy:
		speedlines(pos, color.lightened(0.4), size * v.speedlines_scale, duration * v.speedlines_life)
	sparks(pos, color.lightened(0.35), count, duration)


## Blocked: a flat-out ring and a few short sparks, no star.
func guard_spark(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var v := Tuning.vfx
	flash(pos, color, size * 1.2, duration, true)
	var r := sprite(Shape.RING, color.lightened(0.3), pos, Vector2.ONE * size * 0.6,
			Vector2.ONE * size * 2.0, duration * v.hit_ring_life, true)
	r.size_trans = Tween.TRANS_EXPO
	r.size_ease = Tween.EASE_OUT
	sparks(pos, color.lightened(0.5), v.spark_count_light / 2, duration * 0.7)


## Spiky impact star, popping out then collapsing.
func star(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var v := Tuning.vfx
	var fx := sprite(Shape.STAR, color, pos, Vector2.ONE * size * v.star_scale.x,
			Vector2.ONE * size * v.star_scale.y, duration, true)
	fx.size_trans = Tween.TRANS_BACK
	fx.size_ease = Tween.EASE_OUT
	fx.fade_from = 1.0


## `count` streaks flying outward from `pos`, shrinking as they go.
func sparks(pos: Vector3, color: Color, count: int, duration: float) -> void:
	var v := Tuning.vfx
	for i in count:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.5, 1), randf_range(-1, 1)).normalized()
		var d := duration * randf_range(v.spark_life.x, v.spark_life.y)
		var length := v.spark_length * randf_range(0.7, 1.3)
		var fx := sprite(Shape.STREAK, color, pos, Vector2(v.spark_size, length),
				Vector2(v.spark_size * 0.3, length * 0.4), d, true, Facing.AXIS, dir)
		fx.pos_to = pos + dir * v.spark_speed * d
		fx.pos_trans = Tween.TRANS_CUBIC
		fx.pos_ease = Tween.EASE_OUT


## Round flash orb, dissolving from the edge.
func flash(pos: Vector3, color: Color, size: float, duration: float, on_top: bool = false) -> void:
	var fx := sprite(Shape.ORB, color, pos, Vector2.ONE * size * 0.4, Vector2.ONE * size, duration, on_top)
	fx.size_trans = Tween.TRANS_QUAD
	fx.size_ease = Tween.EASE_OUT
	fx.fade_from = 1.0


## Camera-facing shock ring.
func ring(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := sprite(Shape.RING, color, pos, Vector2.ONE * size * 0.25, Vector2.ONE * size, duration)
	fx.size_trans = Tween.TRANS_EXPO
	fx.size_ease = Tween.EASE_OUT


## Ring lying on the floor at `feet` (y = 0 = the floor).
func ground_ring(feet: Vector3, color: Color, size: float, duration: float) -> void:
	var p := Vector3(feet.x, Tuning.vfx.ground_bounce_height, feet.z)
	var fx := sprite(Shape.RING, color, p, Vector2.ONE * size * 0.2, Vector2.ONE * size, duration,
			false, Facing.NODE)
	fx.mi.basis = _flat
	_apply(fx)  # the basis reset its scale
	fx.size_trans = Tween.TRANS_EXPO
	fx.size_ease = Tween.EASE_OUT


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


## Radial speed lines flying out of `pos`.
func speedlines(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := sprite(Shape.SPEEDLINES, color, pos, Vector2.ONE * size * 0.8, Vector2.ONE * size, duration, true)
	fx.fade_from = 1.0


## Spinning glint (ki flares, perfect dodges, counters).
func glint(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := sprite(Shape.FLARE, color, pos, Vector2.ONE * size, Vector2.ONE * size * 1.4, duration, true)
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
				Vector2(v.spark_size * 0.4, v.teleport_streak_length * 0.3), duration * 1.2, false, Facing.AXIS, dir)
		fx.pos_to = start + dir * v.teleport_streak_speed * duration
		fx.pos_trans = Tween.TRANS_EXPO
		fx.pos_ease = Tween.EASE_OUT


# --- primitives ----------------------------------------------------------------

## Fighter in `slot` of `f`'s match (read only), or null.
func _director_fighter(f: Fighter, slot: int) -> Fighter:
	if slot < 0 or f.director == null:
		return null
	return f.director.fighter_for_slot(slot)


func _new_fx(on_top: bool) -> Fx:
	var fx := Fx.new()
	fx.on_top = on_top
	fx.mi = FxMaterials.sprite(Shape.ORB, Color.WHITE, Facing.CAMERA, on_top)
	fx.mi.visible = false
	add_child(fx.mi)
	return fx


## A pooled sprite drawing `shape` at `pos` (VfxManager is at the world
## origin), sized `size_from` -> `size_to` (m) over `duration`. Linear
## unless the caller changes the curves on the returned Fx.
func sprite(shape: FxMaterials.Shape, color: Color, pos: Vector3, size_from: Vector2, size_to: Vector2,
		duration: float, on_top: bool = false, facing: FxMaterials.Facing = Facing.CAMERA,
		dir: Vector3 = Vector3.UP) -> Fx:
	var pool := _free_on_top if on_top else _free
	var fx: Fx = pool.pop_back() if not pool.is_empty() else _new_fx(on_top)
	var mi := fx.mi
	mi.basis = Basis.IDENTITY
	mi.set_instance_shader_parameter(&"fx_shape", shape)
	mi.set_instance_shader_parameter(&"fx_facing", facing)
	mi.set_instance_shader_parameter(&"fx_dir", dir)
	mi.set_instance_shader_parameter(&"fx_seed", randf())
	mi.set_instance_shader_parameter(&"fx_spin", 0.0)
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
	mi.scale = Vector3(maxf(s.x, 0.001), maxf(s.y, 0.001), 1.0)
	var c := fx.color
	if k > fx.fade_from:
		c.a *= 1.0 - (k - fx.fade_from) / maxf(1.0 - fx.fade_from, 0.001)
	mi.set_instance_shader_parameter(&"fx_color", c)
	mi.set_instance_shader_parameter(&"fx_progress", k)


func _release(fx: Fx) -> void:
	fx.mi.visible = false
	(_free_on_top if fx.on_top else _free).append(fx)


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
