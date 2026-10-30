class_name VfxManager
extends Node3D
## Spawns short-lived, visual-only effects in the shared world in response to
## fighter events (via MatchEventHub). Effects are tweened meshes; no gameplay
## state is touched. Ki charge auras are drawn by fighter visuals, not here.
##
## Handled events: &"hit" {position, heavy, blocked, attacker_slot},
## &"perfect_dodge", &"teleport" / &"vanish" {from?, to?, position?},
## &"guard_break", &"ko", &"ultimate_start", &"push_off", &"counter_guard",
## &"throw", &"throw_break", &"ground_bounce", &"taunt_done". Blocked hits
## are tinted by guard_result (ki guard). Co-op: &"entry" (enemy appears),
## &"downed", &"revived", &"lock_broken".

var hub: MatchEventHub
var _sphere: SphereMesh
var _box: BoxMesh
var _ring: TorusMesh


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
	FxMaterials.warm_up(self)


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
## A copy of an FxMaterials template, so its shader outlives the effect.
func _additive(color: Color, on_top: bool = false) -> StandardMaterial3D:
	return FxMaterials.make(FxMaterials.Kind.TRANSLUCENT_ON_TOP if on_top else FxMaterials.Kind.TRANSLUCENT, color)


func _spawn(mesh: Mesh, color: Color, pos: Vector3, on_top: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _additive(color, on_top)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = pos
	return mi


## Expanding, fading sphere.
func flash(pos: Vector3, color: Color, size: float, duration: float, on_top: bool = false) -> void:
	var mi := _spawn(_sphere, color, pos, on_top)
	mi.scale = Vector3.ONE * size * 0.3
	var mat := mi.material_override as StandardMaterial3D
	var tw := mi.create_tween().set_parallel()
	tw.tween_property(mi, "scale", Vector3.ONE * size, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(mi.queue_free)


## Flash + sparks flying outward.
func hit_spark(pos: Vector3, color: Color, size: float, duration: float, count: int) -> void:
	flash(pos, Color(color, 0.75), size, duration, true)
	flash(pos, Color(1, 1, 1, 0.95), size * 0.45, duration * 0.6, true)
	var v := Tuning.vfx
	for i in count:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.6, 1), randf_range(-1, 1)).normalized()
		var mi := _spawn(_box, color.lightened(0.3), pos, true)
		mi.scale = Vector3(v.spark_size, v.spark_size, v.spark_size * 5.0)
		if absf(dir.dot(Vector3.UP)) < 0.98:
			mi.look_at(pos + dir, Vector3.UP)
		var d := duration * randf_range(1.2, 2.0)
		var mat := mi.material_override as StandardMaterial3D
		var tw := mi.create_tween().set_parallel()
		tw.tween_property(mi, "global_position", pos + dir * v.spark_speed * d, d).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(mi, "scale", Vector3(0.01, 0.01, v.spark_size * 2.0), d)
		tw.tween_property(mat, "albedo_color:a", 0.0, d)
		tw.chain().tween_callback(mi.queue_free)


## Flat expanding ring facing up.
func shockwave(pos: Vector3, color: Color, size: float, duration: float) -> void:
	var mi := _spawn(_ring, color, pos)
	mi.scale = Vector3.ONE * 0.2
	var mat := mi.material_override as StandardMaterial3D
	var tw := mi.create_tween().set_parallel()
	tw.tween_property(mi, "scale", Vector3(size, size * 0.5, size), duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration)
	tw.chain().tween_callback(mi.queue_free)


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
