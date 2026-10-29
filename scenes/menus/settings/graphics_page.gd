class_name GraphicsPage
extends SettingsPage
## Settings > Graphics: edits Settings.video and applies it live.
##
## Display changes (window mode, window size) are staged: they apply once
## the player stops changing them for Tuning.video.display_apply_delay
## seconds (any input while focus is on a display row, or typing in a size
## field, restarts the wait; leaving the page applies at once), then a "Keep these display settings?" prompt counts down
## Tuning.video.revert_seconds and reverts unless confirmed, so a mode the
## screen can't show undoes itself. Only confirmed values are saved. Every
## other option applies and saves immediately.
##
## Window size rows only matter in windowed mode (fullscreen uses the
## desktop resolution; Render scale is the lever there), so they are
## disabled otherwise. Presets larger than the screen are hidden; Width /
## Height steppers give any custom size, clamped to the screen on apply.
##
## Rows the platform can't honour are hidden (PlatformCaps): window mode,
## size and VSync on web (the browser owns the window), the upscaler
## wherever FSR is unavailable (Compatibility renderer, so always on web).

const MODE_LABELS := ["Windowed", "Borderless fullscreen", "Fullscreen (exclusive)"]
const UPSCALER_LABELS := ["Bilinear", "FSR 1.0", "FSR 2.2"]
const VSYNC_LABELS := ["Off", "On", "Adaptive"]
const SHADOW_LABELS := ["Off", "Low", "High"]
const OFF_ON := ["Off", "On"]
const CUSTOM_LABEL := "Custom"
const UNLIMITED_LABEL := "Unlimited"
const SIZE_HELP := "Window size in windowed mode. Fullscreen uses the desktop resolution: use Render scale instead."
const CUSTOM_HELP := "Custom window size: type a number (or click / Enter first), or hold left/right."
const SIZE_DISABLED_HELP := "Window size only applies in windowed mode: set Window mode to Windowed first."

var mode_sel: OptionSelector
var size_sel: OptionSelector
var width_step: NumberStepper
var height_step: NumberStepper
var render_sel: OptionSelector
var upscaler_sel: OptionSelector
var vsync_sel: OptionSelector
var fps_sel: OptionSelector
var smooth_sel: OptionSelector
var shadow_sel: OptionSelector
var ui_sel: OptionSelector

## Staged display values (applied after the debounce).
var pending_mode := 0
var pending_size := Vector2i.ZERO
var _presets: Array[Vector2i] = []
var _debounce: Timer


func _init() -> void:
	super()
	title = "GRAPHICS"


func _ready() -> void:
	var v := Settings.video
	var t := Tuning.video
	pending_mode = v.window_mode
	pending_size = v.window_size
	_presets = VideoSettings.presets_for(Settings.usable_screen_size())
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.timeout.connect(_on_debounce)
	add_child(_debounce)

	mode_sel = _selector("Window mode", MODE_LABELS, v.window_mode,
			"Borderless fills the screen at desktop resolution; exclusive fullscreen may lower latency.")
	mode_sel.value_changed.connect(func(i: int) -> void:
		pending_mode = i
		_stage())
	size_sel = _selector("Window size", _size_labels(), 0, SIZE_HELP)
	size_sel.value_changed.connect(_on_size_preset)
	var usable := Settings.usable_screen_size()
	var max_size := usable if usable.x > 0 else _largest_preset()
	width_step = NumberStepper.new().setup("Width", t.window_size_min.x, max_size.x, v.window_size.x,
			t.window_size_step, t.window_size_step_fast)
	height_step = NumberStepper.new().setup("Height", t.window_size_min.y, max_size.y, v.window_size.y,
			t.window_size_step, t.window_size_step_fast)
	for s: NumberStepper in [width_step, height_step]:
		s.custom_minimum_size.y = UiTheme.tuning().button_min_size.y
		s.value_changed.connect(_on_custom_size.unbind(1))
		add_row(s, CUSTOM_HELP)

	render_sel = _selector("Render scale", SettingsPage.percent_labels(t.render_scale_steps),
			t.render_scale_steps.find(v.render_scale),
			"3D resolution as a share of the screen's pixels. Lower = faster; menus and HUD stay sharp.")
	render_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_render_scale(Tuning.video.render_scale_steps[i])
		_apply_now())
	upscaler_sel = _selector("Upscaler", UPSCALER_LABELS, v.upscaler,
			"How the 3D is scaled up when Render scale is below 100%. FSR keeps edges sharper.")
	upscaler_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_upscaler(i)
		_apply_now())
	vsync_sel = _selector("VSync", VSYNC_LABELS, v.vsync,
			"Sync frames to the display to avoid tearing. Adaptive tears only when the game falls behind.")
	vsync_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_vsync(i)
		_apply_now())
	fps_sel = _selector("Max FPS", _fps_labels(), t.max_fps_options.find(v.max_fps),
			"Frame rate cap. The game simulates at 60 Hz; higher rates look smoother with Motion smoothing.")
	fps_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_max_fps(Tuning.video.max_fps_options[i])
		_apply_now())
	smooth_sel = _selector("Motion smoothing", OFF_ON, 1 if v.motion_smoothing else 0,
			"Blend fighter movement between 60 Hz game ticks on faster displays. Off shows raw tick positions (up to 1 frame sooner).")
	smooth_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.motion_smoothing = i == 1
		_apply_now())
	shadow_sel = _selector("Shadows", SHADOW_LABELS, v.shadow_quality, "Sun shadow quality.")
	shadow_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_shadow_quality(i)
		_apply_now())
	ui_sel = _selector("UI scale", SettingsPage.percent_labels(t.ui_scale_steps),
			t.ui_scale_steps.find(v.ui_scale), "Size of menus and the HUD (e.g. larger for a TV across the room).")
	ui_sel.value_changed.connect(func(i: int) -> void:
		Settings.video.set_ui_scale(Tuning.video.ui_scale_steps[i])
		_apply_now())
	add_reset_row("Graphics", _reset)
	var window_rows := PlatformCaps.window_control()
	for c: Control in _display_rows() + [vsync_sel]:
		c.visible = window_rows
	upscaler_sel.visible = PlatformCaps.fsr()
	_sync_rows()


func _selector(text: String, labels: Array, index: int, help: String) -> OptionSelector:
	var s := MenuHelpers.selector(text, PackedStringArray(labels), maxi(index, 0))
	add_row(s, help)
	return s


func _size_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _presets:
		out.append("%d x %d" % [p.x, p.y])
	out.append(CUSTOM_LABEL)
	return out


func _fps_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for f in Tuning.video.max_fps_options:
		out.append(UNLIMITED_LABEL if f == 0 else str(f))
	return out


func _largest_preset() -> Vector2i:
	var m := Tuning.video.window_size_min
	for p in Tuning.video.window_size_presets:
		m = m.max(p)
	return m


## Refresh every row from Settings.video + the staged display values.
func _sync_rows() -> void:
	var v := Settings.video
	var t := Tuning.video
	mode_sel.index = pending_mode
	var preset := _presets.find(pending_size)
	size_sel.index = preset if preset >= 0 else _presets.size()
	width_step.value = clampi(pending_size.x, width_step.min_value, width_step.max_value)
	height_step.value = clampi(pending_size.y, height_step.min_value, height_step.max_value)
	render_sel.index = maxi(t.render_scale_steps.find(v.render_scale), 0)
	upscaler_sel.index = v.upscaler
	vsync_sel.index = v.vsync
	fps_sel.index = maxi(t.max_fps_options.find(v.max_fps), 0)
	smooth_sel.index = 1 if v.motion_smoothing else 0
	shadow_sel.index = v.shadow_quality
	ui_sel.index = maxi(t.ui_scale_steps.find(v.ui_scale), 0)
	var windowed := pending_mode == VideoSettings.WindowMode.WINDOWED
	for c: Button in [size_sel, width_step, height_step]:
		c.disabled = not windowed
		var help := SIZE_HELP if c == size_sel else CUSTOM_HELP
		c.set_meta(&"help", help if windowed else SIZE_DISABLED_HELP)
	upscaler_sel.disabled = v.render_scale >= 1.0
	relink()


func _on_size_preset(i: int) -> void:
	if i < _presets.size():
		pending_size = _presets[i]
		width_step.value = pending_size.x
		height_step.value = pending_size.y
		_stage()


func _on_custom_size() -> void:
	pending_size = Vector2i(width_step.value, height_step.value)
	var preset := _presets.find(pending_size)
	size_sel.index = preset if preset >= 0 else _presets.size()
	_stage()


## A display value changed: (re)start the debounce.
func _stage() -> void:
	_sync_rows()
	if pending_mode == Settings.video.window_mode and pending_size == Settings.video.window_size:
		_debounce.stop()
		status.emit("", false)
		return
	_debounce.start(Tuning.video.display_apply_delay)
	status.emit("Display change applies %d s after your last edit." % ceili(Tuning.video.display_apply_delay), false)


func has_pending() -> bool:
	return not _debounce.is_stopped()


func _display_rows() -> Array[Control]:
	return [mode_sel, size_sel, width_step, height_step]


## Still editing the display rows: push the pending apply back.
func _input(event: InputEvent) -> void:
	if not has_pending() or not is_visible_in_tree() or not event.is_pressed():
		return
	if get_viewport().gui_get_focus_owner() in _display_rows():
		_debounce.start(Tuning.video.display_apply_delay)


func _on_debounce() -> void:
	if width_step.is_typing() or height_step.is_typing():
		_debounce.start(Tuning.video.display_apply_delay)
		return
	apply_pending()


## Apply the staged display values and ask to keep them.
func apply_pending() -> void:
	_debounce.stop()
	var v := Settings.video
	if pending_mode == v.window_mode and pending_size == v.window_size:
		return
	var before := v.to_dict()
	v.set_window_mode(pending_mode)
	v.set_window_size(pending_size)
	Settings.apply_video()
	_prompt = ConfirmPrompt.open(_prompt_parent(), "Keep these display settings?", "Keep", "Revert",
			Tuning.video.revert_seconds)
	_prompt.resolved.connect(func(keep: bool) -> void:
		_prompt = null
		if keep:
			_save()
			status.emit("Display settings kept.", false)
		else:
			Settings.video.from_dict(before)
			Settings.apply_video()
			pending_mode = Settings.video.window_mode
			pending_size = Settings.video.window_size
			_sync_rows()
			status.emit("Display settings reverted.", false))


## A non-display option changed: apply + save now.
func _apply_now() -> void:
	Settings.apply_video()
	_save()
	_sync_rows()


func _save() -> void:
	if Settings.video.save() != OK:
		status.emit("Could not save video settings", true)


func _reset() -> void:
	var v := Settings.video
	var mode := v.window_mode
	var size := v.window_size
	v.reset_defaults()
	# Display values go through the confirm flow like any display change
	# (and stay put where the browser owns the window).
	pending_mode = v.window_mode if PlatformCaps.window_control() else mode
	pending_size = v.window_size if PlatformCaps.window_control() else size
	v.set_window_mode(mode)
	v.set_window_size(size)
	Settings.apply_video()
	_save()
	_sync_rows()
	if pending_mode != mode or pending_size != size:
		apply_pending()


func is_busy() -> bool:
	return super() or width_step.is_typing() or height_step.is_typing()


func flush() -> bool:
	if width_step.is_typing():
		width_step.commit_typing()
	if height_step.is_typing():
		height_step.commit_typing()
	if has_pending():
		apply_pending()
	return is_busy()
