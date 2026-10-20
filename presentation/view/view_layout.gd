class_name ViewLayout
extends Control
## Builds the on-screen views for a match.
##   SPLIT_SCREEN: one view per local slot (config.local_view_slots(), in
##                 slot order, up to Tuning.net.max_fighters), all sharing the
##                 main World3D. Two views sit side by side (left = lowest
##                 slot); 3-4 views fill a 2x2 grid row-major (a 3-view grid
##                 leaves a plain filler in the 4th cell). Dividers between
##                 views are the divider colour showing through the gaps.
##   SINGLE_VIEW:  one full-screen view for config.local_view_slots()[0]
##                 (VERSUS_CPU, ONLINE and any future mode).
## Only the first view listens for 3D audio (one listener per machine).
## Each view = Control(clip) > SubViewportContainer(stretch) > SubViewport >
## FighterCamera, plus a full-rect tint ColorRect for per-view flashes.
##
## Resolution: a stretched container sizes its SubViewport in canvas units,
## which under the canvas_items stretch mode is the 1152x648-ish base size,
## not the window's pixels. So each container is sized to its panel times the
## window's canvas->pixel scale and drawn scaled back down: the 3D renders at
## native pixels, then Settings.configure_viewport() applies the player's
## render scale + upscaler. Refit on panel resize, window resize and
## Settings.video_applied (UI scale changes the canvas scale).
##
## Also routes presentation events (MatchEventHub) to the cameras. In co-op
## an ultimate's orbit cinematic plays only on its caster's view (the other
## views get CoopViewHud's banner instead); in versus every view orbits.

## Split screen with 3-4 views: a GRID_COLUMNS x GRID_COLUMNS grid.
const GRID_COLUMNS := 2

var cameras: Dictionary = {}  # slot -> FighterCamera
## slot -> that view's clip Control (overlays like CoopViewHud go inside).
var panels: Dictionary = {}
var _coop := false
var _tints: Dictionary = {}  # slot -> ColorRect
var _tint_tweens: Dictionary = {}  # slot -> Tween
## panel Control -> its SubViewportContainer.
var _containers: Dictionary = {}


func _init() -> void:
	name = "ViewLayout"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func build(config: MatchConfig, fighters: Array[Fighter], world: World3D, hub: MatchEventHub) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_coop = config.mode == MatchConfig.Mode.COOP
	var slots: Array[int] = config.local_view_slots()
	slots.sort()
	var is_split := config.layout() == MatchConfig.Layout.SPLIT_SCREEN and slots.size() >= 2
	if not is_split:
		slots = [slots[0] if not slots.is_empty() else 0]
	else:
		slots = slots.slice(0, mini(slots.size(), Tuning.net.max_fighters))
	# Side by side views are half width / full height: the camera widens its
	# FOV for that. Grid cells keep the screen's aspect (full-screen FOV).
	var half_width := slots.size() == 2

	var views := _views_container(slots.size())
	for i in slots.size():
		if i > 0 and views is HBoxContainer:
			var div := ColorRect.new()
			div.name = "Divider"
			div.color = Tuning.hud.divider_color
			div.custom_minimum_size.x = Tuning.hud.divider_width
			div.mouse_filter = Control.MOUSE_FILTER_IGNORE
			views.add_child(div)
		var f := _fighter_for(fighters, slots[i])
		if f != null:
			var view := _make_view(f, half_width, i == 0, world)
			views.add_child(view)
			panels[f.slot] = view
	if views is GridContainer:
		for i in range(slots.size(), GRID_COLUMNS * GRID_COLUMNS):
			var filler := ColorRect.new()
			filler.name = "Filler"
			filler.color = Tuning.hud.split_filler_color
			filler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
			filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
			views.add_child(filler)

	if hub != null:
		hub.fighter_event.connect(_on_fighter_event.bind(hub))
	get_viewport().size_changed.connect(_refit_all)
	Settings.video_applied.connect(_on_video_applied)


## A row for one or two views, else a 2x2 grid over a divider-coloured
## backdrop (its gaps are the dividers).
func _views_container(count: int) -> Container:
	var views: Container
	if count <= 2:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		views = row
	else:
		var backdrop := ColorRect.new()
		backdrop.name = "Dividers"
		backdrop.color = Tuning.hud.divider_color
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(backdrop)
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var grid := GridContainer.new()
		grid.columns = GRID_COLUMNS
		var gap := roundi(Tuning.hud.divider_width)
		grid.add_theme_constant_override("h_separation", gap)
		grid.add_theme_constant_override("v_separation", gap)
		views = grid
	views.name = "Views"
	views.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(views)
	views.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return views


func _fighter_for(fighters: Array[Fighter], slot: int) -> Fighter:
	for f in fighters:
		if f.slot == slot:
			return f
	return fighters[0] if not fighters.is_empty() else null


func _make_view(f: Fighter, half_width: bool, listener: bool, world: World3D) -> Control:
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
	_containers[panel] = container
	panel.resized.connect(_fit.bind(panel))

	var vp := SubViewport.new()
	vp.name = "SubViewport"
	vp.world_3d = world
	vp.audio_listener_enable_3d = listener
	vp.handle_input_locally = false
	vp.msaa_3d = Viewport.MSAA_2X
	vp.positional_shadow_atlas_size = 0
	Settings.configure_viewport(vp)
	container.add_child(vp)

	var cam := FighterCamera.new()
	cam.setup(f, half_width)
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


## Canvas units -> window pixels for this layout's viewport.
func pixel_scale() -> float:
	var sc := get_viewport().get_final_transform().get_scale()
	return maxf(minf(sc.x, sc.y), 0.01)


func _fit(panel: Control) -> void:
	var c: SubViewportContainer = _containers.get(panel)
	if c == null:
		return
	var k := pixel_scale()
	c.position = Vector2.ZERO
	c.scale = Vector2.ONE / k
	c.size = panel.size * k


func _refit_all() -> void:
	for panel: Control in _containers:
		_fit(panel)


func _on_video_applied() -> void:
	for c: SubViewportContainer in _containers.values():
		for vp in c.get_children():
			if vp is SubViewport:
				Settings.configure_viewport(vp)
	_refit_all.call_deferred()


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
		&"push_off":
			_shake(f.slot, t.trauma_push_off)
		&"counter_guard":
			_shake(f.slot, t.trauma_counter_guard)
			if cameras.has(f.slot):
				(cameras[f.slot] as FighterCamera).fov_punch(t.counter_guard_fov_punch)
			flash(f.slot, Tuning.vfx.counter_tint_color, Tuning.vfx.counter_tint_duration)
		&"throw_break":
			_shake(f.slot, t.trauma_throw_break)
		&"ground_bounce":
			_shake(f.slot, t.trauma_ground_bounce)
		&"ko":
			_shake(f.slot, t.trauma_ko)
		&"ultimate_start":
			for s: int in cameras:
				if not _coop or s == f.slot:
					(cameras[s] as FighterCamera).play_ultimate_cinematic(f, s == f.slot)
			flash(-1, Tuning.vfx.ultimate_tint_color, Tuning.vfx.ultimate_tint_duration)
