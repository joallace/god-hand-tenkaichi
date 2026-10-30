class_name VfxManager
extends Node3D
## Spawns short-lived, visual-only effects in the shared world in response to
## fighter events (via MatchEventHub). No gameplay state is touched. Ki charge
## auras are drawn by fighter visuals, not here.
##
## Flashes, sparks and shockwaves are pooled meshes (each with its own
## material, built once) animated in _process, not new nodes + materials +
## tweens per effect: on the web build creating those cost ~2 ms per heavy
## hit, enough to drop a frame. Pools are prefilled at setup and grow on
## demand; a finished effect is hidden and goes back to its pool.
##
## Handled events: &"hit" {position, heavy, blocked, attacker_slot},
## &"perfect_dodge", &"teleport" / &"vanish" {from?, to?, position?},
## &"guard_break", &"ko", &"ultimate_start", &"push_off", &"counter_guard",
## &"throw", &"throw_break", &"ground_bounce", &"taunt_done". Blocked hits
## are tinted by guard_result (ki guard). Co-op: &"entry" (enemy appears),
## &"downed", &"revived", &"lock_broken".

## One pooled effect mesh and its animation (Tween.interpolate_value curves).
class Fx:
	var mi: MeshInstance3D
	var mat: StandardMaterial3D
	var on_top: bool
	var t := 0.0
	var duration := 1.0
	var pos_from := Vector3.ZERO
	var pos_to := Vector3.ZERO
	var pos_trans := Tween.TRANS_LINEAR
	var pos_ease := Tween.EASE_IN_OUT
	var scale_from := Vector3.ONE
	var scale_to := Vector3.ONE
	var scale_trans := Tween.TRANS_LINEAR
	var scale_ease := Tween.EASE_IN_OUT
	var alpha_from := 1.0

var hub: MatchEventHub
var _sphere: SphereMesh
var _box: BoxMesh
var _ring: TorusMesh
var _active: Array[Fx] = []
var _free: Array[Fx] = []  # not drawn on top
var _free_on_top: Array[Fx] = []


func _init() -> void:
	name = "Vfx"


func setup(p_hub: MatchEventHub) -> void:
	hub = p_hub
	hub.fighter_event.connect(_on_fighter_event)
	_sphere = SphereMesh.new()
	_sphere.radius = 0.5
	_sphere.height = 1.0
	_sphere.radial_segments = 16
	_sphere.rings = 8
	_box = BoxMesh.new()
	_ring = TorusMesh.new()
	_ring.inner_radius = 0.45
	_ring.outer_radius = 0.5
	_ring.rings = 32
	_ring.ring_segments = 6
	var v := Tuning.vfx
	for i in v.fx_pool_prefill:
		_free.append(_new_fx(false))
	for i in v.fx_pool_prefill_on_top:
		_free_on_top.append(_new_fx(true))
	FxMaterials.warm_up(self)


func _process(delta: float) -> void:
	var i := 0
	while i < _active.size():
		var fx := _active[i]
		fx.t = minf(fx.t + delta, fx.duration)
		var mi := fx.mi
		mi.position = Tween.interpolate_value(fx.pos_from, fx.pos_to - fx.pos_from, fx.t, fx.duration,
				fx.pos_trans, fx.pos_ease)
		mi.scale = Tween.interpolate_value(fx.scale_from, fx.scale_to - fx.scale_from, fx.t, fx.duration,
				fx.scale_trans, fx.scale_ease)
		fx.mat.albedo_color.a = fx.alpha_from * (1.0 - fx.t / fx.duration)
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
	match kind:
		&"hit":
			var pos := hub.event_position(hub.hit_victim(f, data), data, v.fallback_hit_height)
			if data.get("blocked", false):
				var ki_guard: bool = data.get("guard_result", -1) == MoveData.GuardResult.KI_GUARD
				hit_spark(pos, v.ki_guard_color if ki_guard else v.blocked_color, v.hit_flash_size,
						v.hit_duration, v.spark_count_light)
			elif data.get("heavy", false):
				hit_spark(pos, v.heavy_hit_color, v.heavy_flash_size, v.heavy_duration, v.spark_count_heavy)
				shockwave(pos, v.heavy_hit_color, v.heavy_flash_size * 2.0, v.heavy_duration)
			else:
				hit_spark(pos, v.hit_color, v.hit_flash_size, v.hit_duration, v.spark_count_light)
		&"perfect_dodge":
			afterimage(f, hub.last_position(f))
		&"teleport", &"vanish":
			var from: Variant = data.get("from", hub.last_position(f))
			var to: Variant = data.get("to", data.get("position", f.global_position))
			var up := Vector3.UP * 1.0
			if from is Vector3:
				flash((from as Vector3) + up, v.teleport_color, v.teleport_flash_size, v.teleport_duration)
			if to is Vector3:
				flash((to as Vector3) + up, v.teleport_color, v.teleport_flash_size, v.teleport_duration)
			if kind == &"vanish" and to is Vector3:
				shockwave((to as Vector3) + up, v.teleport_color, v.vanish_ring_size, v.teleport_duration * 1.5)
		&"guard_break":
			var p := f.global_position + Vector3.UP * v.fallback_hit_height
			hit_spark(p, v.guard_break_color, v.guard_break_size * 0.5, v.guard_break_duration, v.spark_count_heavy)
			shockwave(p, v.guard_break_color, v.guard_break_size, v.guard_break_duration)
		&"push_off":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			hit_spark(p, v.push_off_color, v.push_off_size * 0.5, v.push_off_duration, v.spark_count_heavy)
			shockwave(p, v.push_off_color, v.push_off_size, v.push_off_duration)
		&"counter_guard":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			flash(p, v.counter_color, v.counter_size, v.counter_duration, true)
			shockwave(p, v.counter_color, v.counter_size * 1.5, v.counter_duration)
		&"throw":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			flash(p, v.throw_color, v.throw_size, v.throw_duration, true)
		&"throw_break":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			var thrower := _director_fighter(f, data.get("attacker_slot", -1))
			if thrower != null:
				p = p.lerp(thrower.global_position + Vector3.UP * v.fallback_hit_height, 0.5)
			hit_spark(p, v.throw_break_color, v.throw_break_size * 0.5, v.throw_break_duration, v.spark_count_heavy)
			shockwave(p, v.throw_break_color, v.throw_break_size, v.throw_break_duration)
		&"ground_bounce":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.ground_bounce_height
			shockwave(p, v.ground_bounce_color, v.ground_bounce_size, v.ground_bounce_duration)
		&"taunt_done":
			var p := f.global_position + Vector3.UP * v.fallback_hit_height
			flash(p, v.taunt_ki_color, v.taunt_ki_size, v.taunt_ki_duration)
			shockwave(f.global_position + Vector3.UP * v.ground_bounce_height, v.taunt_ki_color,
					v.taunt_ki_size, v.taunt_ki_duration)
		&"ko":
			var p := f.global_position + Vector3.UP * v.fallback_hit_height
			flash(p, v.ko_color, v.ko_size, v.ko_duration)
			shockwave(p, v.ko_color, v.ko_size * 1.5, v.ko_duration)
		&"ultimate_start":
			var p := f.global_position + Vector3.UP * v.fallback_hit_height
			shockwave(p, v.ultimate_color, 4.0, 0.6)
			flash(p, v.ultimate_color, 2.0, 0.4)
		&"entry":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			flash(p, v.entry_color, v.entry_size, v.entry_duration)
			shockwave(hub.event_position(f, data, 0.0) + Vector3.UP * v.ground_bounce_height, v.entry_color,
					v.entry_size * 1.5, v.entry_duration)
		&"downed":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.ground_bounce_height
			shockwave(p, v.downed_color, v.downed_size, v.downed_duration)
		&"revived":
			var p := f.global_position + Vector3.UP * v.fallback_hit_height
			flash(p, v.revive_color, v.revive_size, v.revive_duration)
			shockwave(f.global_position + Vector3.UP * v.ground_bounce_height, v.revive_color,
					v.revive_size, v.revive_duration)
		&"lock_broken":
			var p := hub.event_position(f, data, 0.0) + Vector3.UP * v.fallback_hit_height
			hit_spark(p, v.lock_broken_color, v.lock_broken_size * 0.5, v.lock_broken_duration, v.spark_count_heavy)
			shockwave(p, v.lock_broken_color, v.lock_broken_size, v.lock_broken_duration)


# --- primitives ----------------------------------------------------------------

## Fighter in `slot` of `f`'s match (read only), or null.
func _director_fighter(f: Fighter, slot: int) -> Fighter:
	if slot < 0 or f.director == null:
		return null
	return f.director.fighter_for_slot(slot)


## Unshaded translucent material. Solid (mix) blending reads better than
## additive against the bright sky. `on_top` draws through bodies (sparks).
## Built with an FxMaterials template's flags, so its shader outlives the effect.
func _additive(color: Color, on_top: bool = false) -> StandardMaterial3D:
	return FxMaterials.make(FxMaterials.Kind.TRANSLUCENT_ON_TOP if on_top else FxMaterials.Kind.TRANSLUCENT, color)


func _new_fx(on_top: bool) -> Fx:
	var fx := Fx.new()
	fx.on_top = on_top
	fx.mat = _additive(Color.WHITE, on_top)
	fx.mi = MeshInstance3D.new()
	fx.mi.material_override = fx.mat
	fx.mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.mi.visible = false
	add_child(fx.mi)
	return fx


## A pooled mesh at `pos` (VfxManager is at the world origin), playing for
## `duration` from scale `scale_from` with alpha `color.a` fading to 0.
func _spawn(mesh: Mesh, color: Color, pos: Vector3, duration: float, scale_from: Vector3,
		on_top: bool = false) -> Fx:
	var pool := _free_on_top if on_top else _free
	var fx: Fx = pool.pop_back() if not pool.is_empty() else _new_fx(on_top)
	fx.mi.mesh = mesh
	fx.mi.basis = Basis.IDENTITY
	fx.mi.position = pos
	fx.mi.scale = scale_from
	fx.mi.visible = true
	fx.mat.albedo_color = color
	fx.t = 0.0
	fx.duration = maxf(duration, 0.001)
	fx.pos_from = pos
	fx.pos_to = pos
	fx.scale_from = scale_from
	fx.scale_to = scale_from
	fx.pos_trans = Tween.TRANS_LINEAR
	fx.scale_trans = Tween.TRANS_LINEAR
	fx.alpha_from = color.a
	_active.append(fx)
	return fx


func _release(fx: Fx) -> void:
	fx.mi.visible = false
	(_free_on_top if fx.on_top else _free).append(fx)


## Expanding, fading sphere.
func flash(pos: Vector3, color: Color, size: float, duration: float, on_top: bool = false) -> void:
	var fx := _spawn(_sphere, color, pos, duration, Vector3.ONE * size * 0.3, on_top)
	fx.scale_to = Vector3.ONE * size
	fx.scale_trans = Tween.TRANS_QUAD
	fx.scale_ease = Tween.EASE_OUT


## Flash + sparks flying outward.
func hit_spark(pos: Vector3, color: Color, size: float, duration: float, count: int) -> void:
	flash(pos, Color(color, 0.75), size, duration, true)
	flash(pos, Color(1, 1, 1, 0.95), size * 0.45, duration * 0.6, true)
	var v := Tuning.vfx
	var spark_color := color.lightened(0.3)
	for i in count:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.6, 1), randf_range(-1, 1)).normalized()
		var d := duration * randf_range(1.2, 2.0)
		var fx := _spawn(_box, spark_color, pos, d, Vector3(v.spark_size, v.spark_size, v.spark_size * 5.0), true)
		if absf(dir.dot(Vector3.UP)) < 0.98:
			fx.mi.look_at(pos + dir, Vector3.UP)
		fx.pos_to = pos + dir * v.spark_speed * d
		fx.pos_trans = Tween.TRANS_CUBIC
		fx.pos_ease = Tween.EASE_OUT
		fx.scale_to = Vector3(0.01, 0.01, v.spark_size * 2.0)


## Flat expanding ring facing up.
func shockwave(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var fx := _spawn(_ring, color, pos, duration, Vector3.ONE * 0.2)
	fx.scale_to = Vector3(size, size * 0.5, size)
	fx.scale_trans = Tween.TRANS_EXPO
	fx.scale_ease = Tween.EASE_OUT


## Translucent copy of the fighter's meshes, fading out.
func afterimage(f: Fighter, at: Vector3) -> void:
	var v := Tuning.vfx
	var ghost := Node3D.new()
	ghost.name = "Afterimage"
	add_child(ghost)
	var offset := at - f.global_position
	var mat := _additive(v.afterimage_color)
	var n := 0
	for node in f.find_children("*", "MeshInstance3D", true, false):
		var src := node as MeshInstance3D
		if src == null or not src.is_visible_in_tree() or src.mesh == null:
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
