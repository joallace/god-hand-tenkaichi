extends Node
## Headless test of the settings models (VideoSettings, AudioSettings), the
## Settings autoload's apply, SmoothedVisual blending, NumberStepper /
## ConfirmPrompt, and the SettingsScreen hub (tabs, live apply, display
## confirm/revert, reset, in-match lock). Run as a scene (needs autoloads):
##   godot --headless res://tests/settings_test.tscn
## Settings.video / Settings.audio / Net.settings are swapped for instances
## on temp files, so the user's config files are never written.

const VIDEO_CFG := "user://settings_test_video.cfg"
const AUDIO_CFG := "user://settings_test_audio.cfg"
const ONLINE_CFG := "user://settings_test_online.cfg"

var _fails := 0
var _real_video: VideoSettings
var _real_audio: AudioSettings
var _real_online: OnlineSettings


func _ready() -> void:
	_real_video = Settings.video
	_real_audio = Settings.audio
	_real_online = Net.settings
	_remove_temp()
	Settings.video = VideoSettings.load_from(VIDEO_CFG)
	Settings.audio = AudioSettings.load_from(AUDIO_CFG)
	Net.settings = OnlineSettings.load_from(ONLINE_CFG)
	_test_video_model()
	_test_audio_model()
	_test_apply()
	await _test_smoothed_visual()
	await _test_number_stepper()
	await _test_confirm_prompt()
	await _test_hub_tabs()
	await _test_graphics_page()
	await _test_audio_page()
	await _test_overlay_in_match()
	Settings.video = _real_video
	Settings.audio = _real_audio
	Net.settings = _real_online
	Settings.apply_video()
	Settings.apply_audio()
	_remove_temp()
	print("SETTINGS %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func seconds(s: float) -> void:
	await get_tree().create_timer(s, true).timeout


func _remove_temp() -> void:
	for p in [VIDEO_CFG, AUDIO_CFG, ONLINE_CFG]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func press(ev: InputEvent) -> void:
	Input.parse_input_event(ev)
	await frames(2)


func pad_button(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	return e


func key(code: Key, unicode := 0, echo := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.unicode = unicode
	e.pressed = true
	e.echo = echo
	return e


func spawn_hub(overlay := false, in_match := false) -> SettingsScreen:
	if overlay:
		return SettingsScreen.open_overlay(self, 10, in_match)
	var s := (load(Game.SCENE_SETTINGS) as PackedScene).instantiate() as SettingsScreen
	add_child(s)
	return s


func prompt_in(n: Node) -> ConfirmPrompt:
	for c in n.get_children():
		if c is ConfirmPrompt and not c.is_queued_for_deletion():
			return c
	return null


# --- models ------------------------------------------------------------------------

func _test_video_model() -> void:
	var t := Tuning.video
	var v := VideoSettings.new()
	check(v.window_mode == t.default_window_mode and v.window_size == t.default_window_size
			and v.motion_smoothing == t.default_motion_smoothing, "video defaults come from Tuning.video")
	v.set_window_mode(99)
	check(v.window_mode == t.default_window_mode, "bad window mode -> default")
	v.set_window_size(Vector2i(10, 10))
	check(v.window_size == t.window_size_min, "window size clamped up to the minimum")
	v.set_render_scale(0.52)
	check(v.render_scale == t.render_scale_steps[0], "render scale snaps to the nearest step")
	v.set_max_fps(37)
	check(v.max_fps == t.default_max_fps, "unknown FPS cap -> default")
	v.set_ui_scale(9.0)
	check(v.ui_scale == t.ui_scale_steps[t.ui_scale_steps.size() - 1], "UI scale snaps into range")

	v.path = VIDEO_CFG
	v.set_window_mode(VideoSettings.WindowMode.BORDERLESS)
	v.set_window_size(Vector2i(1700, 950))
	v.set_render_scale(0.77)
	v.set_upscaler(VideoSettings.Upscaler.FSR2)
	v.set_vsync(VideoSettings.VSync.OFF)
	v.set_max_fps(144)
	v.motion_smoothing = false
	v.set_shadow_quality(VideoSettings.Shadows.LOW)
	check(v.save() == OK, "video settings save")
	var w := VideoSettings.load_from(VIDEO_CFG)
	check(w.to_dict() == v.to_dict(), "video settings round-trip through the file")

	var cf := ConfigFile.new()
	cf.set_value("video", "window_mode", "fullscreen")
	cf.set_value("video", "window_size", "big")
	cf.set_value("video", "max_fps", 1000)
	cf.set_value("video", "motion_smoothing", 1)
	cf.save(VIDEO_CFG)
	w = VideoSettings.load_from(VIDEO_CFG)
	check(w.to_dict() == VideoSettings.new().to_dict(), "garbage values in the file fall back to defaults")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(VIDEO_CFG))

	v = VideoSettings.new()
	v.set_window_size(Vector2i(2560, 1440))
	check(v.fit_window_size(Vector2i(1920, 1040)) == Vector2i(1920, 1040), "window larger than the screen is clamped")
	check(v.window_size == Vector2i(2560, 1440), "clamping doesn't change the stored size")
	check(v.fit_window_size(Vector2i.ZERO) == Vector2i(2560, 1440), "unknown screen -> stored size")
	var fits := VideoSettings.presets_for(Vector2i(1920, 1080))
	check(not fits.is_empty() and fits.all(func(p: Vector2i) -> bool: return p.x <= 1920 and p.y <= 1080),
			"presets larger than the screen are hidden")
	check(VideoSettings.presets_for(Vector2i.ZERO).size() == t.window_size_presets.size(),
			"unknown screen -> every preset")

	v.set_render_scale(1.0)
	v.set_upscaler(VideoSettings.Upscaler.FSR1)
	check(v.scaling_mode() == Viewport.SCALING_3D_MODE_BILINEAR, "no upscaler at 100%")
	v.set_render_scale(0.5)
	check(v.scaling_mode() == Viewport.SCALING_3D_MODE_FSR, "FSR below 100%")


func _test_audio_model() -> void:
	check(AudioServer.get_bus_index(Tuning.sfx.bus) >= 0 and AudioServer.get_bus_index(Tuning.sfx.ui_bus) >= 0,
			"bus layout has the SFX and UI buses")
	check(Sfx.bus_for(&"ui_move") == Tuning.sfx.ui_bus and Sfx.bus_for(&"pause") == Tuning.sfx.ui_bus
			and Sfx.bus_for(&"hit_heavy") == Tuning.sfx.bus, "menu sounds route to UI, the rest to SFX")
	var a := AudioSettings.new()
	a.path = AUDIO_CFG
	a.set_volume(Tuning.sfx.bus, 150)
	check(a.volume(Tuning.sfx.bus) == AudioSettings.MAX_PERCENT, "volume clamped to 100")
	a.set_volume(Tuning.sfx.bus, 40)
	a.set_volume(Tuning.sfx.ui_bus, 0)
	a.save()
	var b := AudioSettings.load_from(AUDIO_CFG)
	check(b.volumes == a.volumes, "audio settings round-trip through the file")
	b.apply()
	var sfx_idx := AudioServer.get_bus_index(Tuning.sfx.bus)
	var ui_idx := AudioServer.get_bus_index(Tuning.sfx.ui_bus)
	check(is_equal_approx(AudioServer.get_bus_volume_db(sfx_idx), linear_to_db(0.4)) and not AudioServer.is_bus_mute(sfx_idx),
			"apply sets the bus volume")
	check(AudioServer.is_bus_mute(ui_idx), "0% mutes the bus")
	Settings.audio.apply()
	check(not AudioServer.is_bus_mute(ui_idx), "re-applying defaults unmutes")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AUDIO_CFG))


func _test_apply() -> void:
	var win := get_window()
	var old_scale := win.content_scale_factor
	var old_fps := Engine.max_fps
	var old_size := win.size
	Settings.apply_display = true
	Settings.video.set_max_fps(144)
	Settings.video.set_ui_scale(1.25)
	Settings.video.motion_smoothing = false
	var fired := [false]
	var on_applied := func() -> void: fired[0] = true
	Settings.video_applied.connect(on_applied)
	Settings.apply_video()
	check(Engine.max_fps == 144 and is_equal_approx(win.content_scale_factor, 1.25) and not SmoothedVisual.enabled
			and fired[0], "apply_video sets the FPS cap, UI scale, smoothing and signals")
	var vp := SubViewport.new()
	Settings.video.set_render_scale(0.67)
	Settings.video.set_upscaler(VideoSettings.Upscaler.FSR1)
	Settings.configure_viewport(vp)
	check(is_equal_approx(vp.scaling_3d_scale, 0.67) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR,
			"configure_viewport sets render scale + upscaler")
	vp.free()
	Settings.video_applied.disconnect(on_applied)
	Settings.video.reset_defaults()
	Settings.apply_video()
	Settings.apply_display = false
	win.content_scale_factor = old_scale
	Engine.max_fps = old_fps
	win.size = old_size
	check(SmoothedVisual.enabled == Tuning.video.default_motion_smoothing, "defaults re-applied")


# --- motion smoothing ------------------------------------------------------------

func _test_smoothed_visual() -> void:
	SmoothedVisual.enabled = true
	var sim := Node3D.new()
	add_child(sim)
	var vis := SmoothedVisual.new()
	sim.add_child(vis)
	await frames(1)
	check(vis.top_level and vis.transform_at(0.5).origin == Vector3.ZERO, "starts snapped to its parent")
	vis.set_physics_process(false)  # drive record() by hand
	sim.global_position = Vector3(0.4, 0, 0)
	vis.record()
	check(vis.transform_at(0.0).origin.is_equal_approx(Vector3.ZERO)
			and vis.transform_at(0.5).origin.is_equal_approx(Vector3(0.2, 0, 0))
			and vis.transform_at(1.0).origin.is_equal_approx(Vector3(0.4, 0, 0)), "blends between the last two ticks")
	vis.record()
	check(vis.transform_at(0.3).origin.is_equal_approx(Vector3(0.4, 0, 0)), "no movement -> holds still")
	sim.global_position = Vector3(0.4 + Tuning.video.smoothing_snap_distance + 1.0, 0, 0)
	vis.record()
	check(vis.transform_at(0.0).origin.is_equal_approx(sim.global_position), "teleport-sized move snaps")
	sim.global_position = Vector3(5, 0, 5)
	SmoothedVisual.enabled = false
	check(vis.transform_at(0.0).origin == Vector3(5, 0, 5), "smoothing off -> raw sim transform")
	check(SmoothedVisual.render_transform_of(sim).origin == Vector3(5, 0, 5)
			and SmoothedVisual.of(sim) == vis, "render_transform_of finds the visual")
	var plain := Node3D.new()
	add_child(plain)
	plain.global_position = Vector3(1, 2, 3)
	check(SmoothedVisual.render_transform_of(plain).origin == Vector3(1, 2, 3), "no visual -> global transform")
	SmoothedVisual.enabled = true
	sim.queue_free()
	plain.queue_free()
	await frames(1)


# --- widgets -----------------------------------------------------------------------

func _test_number_stepper() -> void:
	var s := NumberStepper.new().setup("Width", 640, 1920, 1000, 8, 80)
	add_child(s)
	var got: Array[int] = []
	s.value_changed.connect(func(v: int) -> void: got.append(v))
	s.grab_focus()
	await frames(1)
	s._gui_input(key(KEY_RIGHT))
	check(s.value == 1008 and got == [1008], "right steps up")
	for i in UiTheme.tuning().stepper_fast_after_repeats:
		s._gui_input(key(KEY_RIGHT, 0, true))
	var before := s.value
	s._gui_input(key(KEY_RIGHT, 0, true))
	check(s.value == before + 80, "held repeats switch to the fast step")
	s._gui_input(key(KEY_LEFT))
	check(s.value == before + 72, "a fresh press is a normal step again")
	for ch in "1280":
		s._gui_input(key(KEY_0, ch.unicode_at(0)))
	check(s.is_typing() and s.text.contains("1280_"), "typing digits edits in place")
	s._gui_input(key(KEY_BACKSPACE))
	s._gui_input(key(KEY_0, "5".unicode_at(0)))
	var ev := InputEventAction.new()
	ev.action = &"ui_accept"
	ev.pressed = true
	s._gui_input(ev)
	check(not s.is_typing() and s.value == 1285, "Enter commits the typed value")
	for ch in "99999":
		s._gui_input(key(KEY_0, ch.unicode_at(0)))
	s.commit_typing()
	check(s.value == 1920, "typed values are clamped")
	s.set_value_user(10)
	check(s.value == 640, "set_value_user clamps to the minimum")
	s.labels = {640: "Smallest"}
	s.value = 640
	check(s.text.contains("Smallest"), "value labels replace the number")
	s.disabled = true
	s._gui_input(key(KEY_RIGHT))
	check(s.value == 640, "disabled stepper ignores input")
	s.queue_free()
	await frames(1)


func _test_confirm_prompt() -> void:
	var b := Button.new()
	add_child(b)
	b.grab_focus()
	var p := ConfirmPrompt.open(self, "Sure?", "Yes", "No", 0.2)
	var result: Array = []
	p.resolved.connect(func(yes: bool) -> void: result.append(yes))
	await frames(2)
	check(get_viewport().gui_get_focus_owner() == p.no_btn, "prompt focuses the safe answer")
	await seconds(0.4)
	check(result == [false], "countdown resolves as no")
	await frames(2)
	check(get_viewport().gui_get_focus_owner() == b, "focus returns after the prompt")
	p = ConfirmPrompt.open(self, "Sure?", "Yes", "No")
	result.clear()
	p.resolved.connect(func(yes: bool) -> void: result.append(yes))
	await frames(2)
	p.yes_btn.pressed.emit()
	check(result == [true], "yes button resolves as yes")
	b.queue_free()
	await frames(2)


# --- hub ---------------------------------------------------------------------------

func _test_hub_tabs() -> void:
	var s := spawn_hub()
	await frames(3)
	check(s.current == SettingsScreen.Tab.GRAPHICS and s.graphics.visible and not s.audio.visible,
			"hub opens on Graphics")
	check(s.graphics.is_ancestor_of(get_viewport().gui_get_focus_owner()), "Graphics page has focus")
	check(s.status.text == str(s.graphics.mode_sel.get_meta(&"help")), "status shows the focused row's help")
	await press(pad_button(JOY_BUTTON_LEFT_SHOULDER))
	check(s.current == SettingsScreen.Tab.ONLINE and s.online.visible, "LB wraps to Online")
	await frames(1)
	check(get_viewport().gui_get_focus_owner() == s.online.name_edit, "Online focuses the name field")
	await press(pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	check(s.current == SettingsScreen.Tab.GRAPHICS, "RB wraps back to Graphics")
	await press(key(KEY_E))
	check(s.current == SettingsScreen.Tab.AUDIO, "E = next tab")
	await press(key(KEY_E))
	check(s.current == SettingsScreen.Tab.CONTROLS and s.controls.embedded and not s.controls._back_btn.visible,
			"Controls tab embeds the controls screen without its Back button")
	s.controls.begin_listen("LIGHT")
	await press(pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	check(s.current == SettingsScreen.Tab.CONTROLS and s.controls.is_listening(),
			"no tab switch while rebinding (the press is swallowed)")
	s.controls.cancel_listen()
	await press(key(KEY_Q))
	check(s.current == SettingsScreen.Tab.AUDIO, "Q = previous tab")
	s.tab_buttons[SettingsScreen.Tab.ONLINE].pressed.emit()
	check(s.current == SettingsScreen.Tab.ONLINE, "clicking a tab selects it")
	s.queue_free()
	await frames(2)


func _test_graphics_page() -> void:
	var t := Tuning.video
	var old_delay := t.display_apply_delay
	var old_revert := t.revert_seconds
	t.display_apply_delay = 0.05
	t.revert_seconds = 0.3
	Settings.video.reset_defaults()
	var s := spawn_hub()
	await frames(3)
	var g := s.graphics

	g.ui_sel.cycle(1)
	check(Settings.video.ui_scale == t.ui_scale_steps[t.ui_scale_steps.find(t.default_ui_scale) + 1],
			"UI scale applies live")
	check(VideoSettings.load_from(VIDEO_CFG).ui_scale == Settings.video.ui_scale, "and is saved at once")
	g.render_sel.index = t.render_scale_steps.size() - 1
	check(g.upscaler_sel.disabled, "upscaler disabled at 100% render scale")
	g.render_sel.cycle(-1)
	check(not g.upscaler_sel.disabled and Settings.video.render_scale < 1.0, "upscaler enabled below 100%")
	g.smooth_sel.cycle(1)
	check(SmoothedVisual.enabled == Settings.video.motion_smoothing, "motion smoothing toggles live")

	# Display change: staged, applied after the debounce, then confirmed.
	g.mode_sel.cycle(1)
	check(g.has_pending() and Settings.video.window_mode == VideoSettings.WindowMode.WINDOWED,
			"window mode change is staged, not applied")
	check(g.size_sel.disabled and g.width_step.disabled, "window size rows disabled outside windowed mode")
	await seconds(0.15)
	var p := prompt_in(s)
	check(p != null and Settings.video.window_mode == VideoSettings.WindowMode.BORDERLESS,
			"after the debounce it applies and asks to keep")
	check(VideoSettings.load_from(VIDEO_CFG).window_mode == VideoSettings.WindowMode.WINDOWED,
			"unconfirmed display change not saved")
	await press(pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	check(s.current == SettingsScreen.Tab.GRAPHICS, "tabs locked while the prompt is open")
	await seconds(0.5)
	check(Settings.video.window_mode == VideoSettings.WindowMode.WINDOWED and g.mode_sel.index == 0
			and not g.size_sel.disabled, "no answer -> reverted")

	g.mode_sel.cycle(1)
	g.apply_pending()
	prompt_in(s).resolve(true)
	await frames(2)
	check(VideoSettings.load_from(VIDEO_CFG).window_mode == VideoSettings.WindowMode.BORDERLESS,
			"kept display change is saved")

	# Back while a display change is staged: apply + confirm first.
	g.mode_sel.cycle(-1)
	s.back()
	await frames(2)
	p = prompt_in(s)
	check(p != null and is_instance_valid(s) and not s.is_queued_for_deletion(),
			"back with a staged display change asks to keep it first")
	p.resolve(true)
	await frames(2)

	# Custom size through the steppers picks "Custom".
	g.width_step.set_value_user(1000)
	check(g.size_sel.current() == GraphicsPage.CUSTOM_LABEL and g.pending_size.x == 1000,
			"stepper size not in the presets shows Custom")
	g.apply_pending()
	prompt_in(s).resolve(true)
	await frames(2)
	check(Settings.video.window_size.x == 1000, "custom width applied")

	# Reset: confirm, defaults restored (display part through the keep prompt).
	g.ui_sel.cycle(1)
	var reset_btn: Button = g.rows.get_child(g.rows.get_child_count() - 1)
	reset_btn.pressed.emit()
	await frames(2)
	prompt_in(s).resolve(true)
	await frames(2)
	p = prompt_in(s)
	check(p != null, "reset with a non-default display asks to keep the default display")
	p.resolve(true)
	await frames(2)
	check(Settings.video.to_dict() == VideoSettings.new().to_dict(), "reset restores every default")
	t.display_apply_delay = old_delay
	t.revert_seconds = old_revert
	s.queue_free()
	await frames(2)


func _test_audio_page() -> void:
	var s := spawn_hub()
	await frames(3)
	s.select_tab(SettingsScreen.Tab.AUDIO)
	await frames(2)
	var sl: OptionSelector = s.audio.sliders[Tuning.sfx.bus]
	check(sl.current() == "100%", "effects volume starts at 100%")
	sl.cycle(-1)
	check(Settings.audio.volume(Tuning.sfx.bus) == 100 - Tuning.sfx.volume_step_percent, "volume steps down")
	check(AudioSettings.load_from(AUDIO_CFG).volume(Tuning.sfx.bus) == Settings.audio.volume(Tuning.sfx.bus),
			"volume saved at once")
	sl.index = 1
	sl.cycle(-1)
	check(sl.current() == AudioPage.MUTED_LABEL and AudioServer.is_bus_mute(AudioServer.get_bus_index(Tuning.sfx.bus)),
			"0% shows Muted and mutes the bus")
	sl.cycle(-1)
	check(sl.index == 0, "volume doesn't wrap below 0")
	s.audio._reset()
	check(Settings.audio.volume(Tuning.sfx.bus) == Tuning.sfx.default_volume_percent and sl.current() == "100%",
			"audio reset")
	s.queue_free()
	await frames(2)


func _test_overlay_in_match() -> void:
	var s := spawn_hub(true, true)
	await frames(3)
	check(s.as_overlay and s.get_parent() is CanvasLayer, "overlay opens on its own layer")
	s.select_tab(SettingsScreen.Tab.ONLINE)
	await frames(2)
	var o := s.online
	check(o.locked and not o.name_edit.editable and o.delay_sel.disabled and o.port_step.disabled
			and not o.overlay_sel.disabled, "in-match Online page: session settings read-only, overlay editable")
	var before := Net.settings.player_name
	check(not o.set_name_text("Changed") and Net.settings.player_name == before, "locked name can't change")
	var closed := [false]
	s.closed.connect(func() -> void: closed[0] = true)
	var ev := InputEventAction.new()
	ev.action = &"ui_cancel"
	ev.pressed = true
	await press(ev)
	ev = ev.duplicate()
	ev.pressed = false
	await press(ev)
	check(closed[0], "Esc / B closes the overlay")
	await frames(2)
