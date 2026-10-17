class_name ViewLayout
extends Control
## Builds the on-screen views for a match.
##   SPLIT_SCREEN: two SubViewportContainers side by side (left = first local
##                 slot, right = second), both sharing the main World3D.
##   SINGLE_VIEW:  one full-screen view for config.local_view_slots()[0]
##                 (VERSUS_CPU, ONLINE and any future mode).
## Each view = Control(clip) > SubViewportContainer(stretch) > SubViewport >
## FighterCamera, plus a full-rect tint ColorRect for per-view flashes.
## Containers are anchored full rect, so window resizes are automatic.
##
## Also routes presentation events (MatchEventHub) to the cameras.

var cameras: Dictionary = {}  # slot -> FighterCamera
var _tints: Dictionary = {}  # slot -> ColorRect
var _tint_tweens: Dictionary = {}  # slot -> Tween


func _init() -> void:
	name = "ViewLayout"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func build(config: MatchConfig, fighters: Array[Fighter], world: World3D, hub: MatchEventHub) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var slots: Array[int] = config.local_view_slots()
	var is_split := config.layout() == MatchConfig.Layout.SPLIT_SCREEN and slots.size() >= 2
	if not is_split:
		slots = [slots[0] if not slots.is_empty() else 0]
	else:
		slots = [slots[0], slots[1]]

	var row := HBoxContainer.new()
	row.name = "Views"
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	for i in slots.size():
		if i > 0:
			var div := ColorRect.new()
			div.name = "Divider"
			div.color = Tuning.hud.divider_color
			div.custom_minimum_size.x = Tuning.hud.divider_width
			div.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(div)
		var f := _fighter_for(fighters, slots[i])
		if f != null:
			row.add_child(_make_view(f, is_split, world))

	if hub != null:
		hub.fighter_event.connect(_on_fighter_event.bind(hub))


func _fighter_for(fighters: Array[Fighter], slot: int) -> Fighter:
	for f in fighters:
		if f.slot == slot:
			return f
	return fighters[0] if not fighters.is_empty() else null


func _make_view(f: Fighter, is_split: bool, world: World3D) -> Control:
	var panel := Control.new()
	panel.name = "View%d" % (f.slot + 1)
	panel.clip_contents = true
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var container := SubViewportContainer.new()
	container.name = "Container"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(container)
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var vp := SubViewport.new()
	vp.name = "SubViewport"
	vp.world_3d = world
	vp.audio_listener_enable_3d = f.slot == 0 or not is_split
	vp.handle_input_locally = false
	vp.msaa_3d = Viewport.MSAA_2X
	vp.positional_shadow_atlas_size = 0
	container.add_child(vp)

	var cam := FighterCamera.new()
	cam.setup(f, is_split)
	vp.add_child(cam)
	cameras[f.slot] = cam

	var tint := ColorRect.new()
	tint.name = "Tint"
	tint.color = Color(1, 1, 1, 0)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tint)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tints[f.slot] = tint
	return panel


func snap_cameras() -> void:
	for c: FighterCamera in cameras.values():
		c.snap()


## Brief color flash over one fighter's view (or all views if slot < 0 or
## that fighter has no local view).
func flash(slot: int, color: Color, duration: float) -> void:
	var targets: Array = [slot] if _tints.has(slot) else _tints.keys()
	for s: int in targets:
		var rect: ColorRect = _tints[s]
		if _tint_tweens.has(s) and (_tint_tweens[s] as Tween).is_valid():
			(_tint_tweens[s] as Tween).kill()
		rect.color = color
		var tw := create_tween()
		tw.tween_property(rect, "color:a", 0.0, duration).set_ease(Tween.EASE_OUT)
		_tint_tweens[s] = tw


func _shake(slot_main: int, amount: float) -> void:
	for s: int in cameras:
		var k := 1.0 if s == slot_main else Tuning.camera.shake_other_view_scale
		(cameras[s] as FighterCamera).add_trauma(amount * k)


func _on_fighter_event(f: Fighter, kind: StringName, data: Dictionary, hub: MatchEventHub) -> void:
	var t := Tuning.camera
	match kind:
		&"hit":
			var victim := hub.hit_victim(f, data)
			var amount := t.trauma_hit_light
			if data.get("blocked", false):
				amount = t.trauma_hit_blocked
			elif data.get("heavy", false):
				amount = t.trauma_hit_heavy
				if cameras.has(victim.slot):
					(cameras[victim.slot] as FighterCamera).fov_punch(t.heavy_hit_fov_punch)
			_shake(victim.slot, amount)
		&"perfect_dodge":
			if cameras.has(f.slot):
				(cameras[f.slot] as FighterCamera).fov_punch(t.perfect_dodge_fov_punch)
			flash(f.slot, Tuning.vfx.dodge_tint_color, Tuning.vfx.dodge_tint_duration)
		&"guard_break":
			_shake(f.slot, t.trauma_guard_break)
		&"ko":
			_shake(f.slot, t.trauma_ko)
		&"ultimate_start":
			for s: int in cameras:
				(cameras[s] as FighterCamera).play_ultimate_cinematic(f, s == f.slot)
			flash(-1, Tuning.vfx.ultimate_tint_color, Tuning.vfx.ultimate_tint_duration)
