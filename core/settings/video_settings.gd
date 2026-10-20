class_name VideoSettings
extends RefCounted
## Per-user video settings, not tuning: window mode and size, 3D render
## scale + upscaler, vsync, FPS cap, motion smoothing, shadows, UI scale.
## Stored in `user://video.cfg`; the Settings autoload owns one instance
## (`Settings.video`) and applies it. Defaults and option lists come from
## Tuning.video. Every setter validates, so a hand-edited or stale file can
## only ever produce values the menus offer.
##
## The stored window size is what the player chose; `fit_window_size()`
## clamps it to the current screen at apply time without writing the
## clamped value back (unplugging a big monitor must not lose the choice).

enum WindowMode { WINDOWED, BORDERLESS, FULLSCREEN }
enum Upscaler { BILINEAR, FSR1, FSR2 }
enum VSync { OFF, ON, ADAPTIVE }
enum Shadows { OFF, LOW, HIGH }

const DEFAULT_PATH := "user://video.cfg"
const _SECTION := "video"

var path := DEFAULT_PATH
var window_mode: int
var window_size: Vector2i
var render_scale: float
var upscaler: int
var vsync: int
var max_fps: int
var motion_smoothing: bool
var shadow_quality: int
var ui_scale: float


func _init() -> void:
	reset_defaults()


static func load_from(p: String = DEFAULT_PATH) -> VideoSettings:
	var s := VideoSettings.new()
	s.path = p
	s.reload()
	return s


func reset_defaults() -> void:
	var t := Tuning.video
	set_window_mode(t.default_window_mode)
	set_window_size(t.default_window_size)
	set_render_scale(t.default_render_scale)
	set_upscaler(t.default_upscaler)
	set_vsync(t.default_vsync)
	set_max_fps(t.default_max_fps)
	motion_smoothing = t.default_motion_smoothing
	set_shadow_quality(t.default_shadow_quality)
	set_ui_scale(t.default_ui_scale)


## Re-read `path` (missing file or keys = defaults).
func reload() -> void:
	reset_defaults()
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	set_window_mode(_int(cf.get_value(_SECTION, "window_mode", window_mode), window_mode))
	var ws: Variant = cf.get_value(_SECTION, "window_size", window_size)
	if ws is Vector2i:
		set_window_size(ws)
	set_render_scale(_float(cf.get_value(_SECTION, "render_scale", render_scale), render_scale))
	set_upscaler(_int(cf.get_value(_SECTION, "upscaler", upscaler), upscaler))
	set_vsync(_int(cf.get_value(_SECTION, "vsync", vsync), vsync))
	set_max_fps(_int(cf.get_value(_SECTION, "max_fps", max_fps), max_fps))
	var ms: Variant = cf.get_value(_SECTION, "motion_smoothing", motion_smoothing)
	motion_smoothing = ms if ms is bool else motion_smoothing
	set_shadow_quality(_int(cf.get_value(_SECTION, "shadow_quality", shadow_quality), shadow_quality))
	set_ui_scale(_float(cf.get_value(_SECTION, "ui_scale", ui_scale), ui_scale))


func save() -> Error:
	var cf := ConfigFile.new()
	cf.set_value(_SECTION, "window_mode", window_mode)
	cf.set_value(_SECTION, "window_size", window_size)
	cf.set_value(_SECTION, "render_scale", render_scale)
	cf.set_value(_SECTION, "upscaler", upscaler)
	cf.set_value(_SECTION, "vsync", vsync)
	cf.set_value(_SECTION, "max_fps", max_fps)
	cf.set_value(_SECTION, "motion_smoothing", motion_smoothing)
	cf.set_value(_SECTION, "shadow_quality", shadow_quality)
	cf.set_value(_SECTION, "ui_scale", ui_scale)
	return cf.save(path)


## Plain copy of every setting (revert snapshots, tests).
func to_dict() -> Dictionary:
	return {
		"window_mode": window_mode, "window_size": window_size, "render_scale": render_scale,
		"upscaler": upscaler, "vsync": vsync, "max_fps": max_fps,
		"motion_smoothing": motion_smoothing, "shadow_quality": shadow_quality, "ui_scale": ui_scale,
	}


## Restore from to_dict() (validated like a file).
func from_dict(d: Dictionary) -> void:
	set_window_mode(_int(d.get("window_mode"), window_mode))
	var ws: Variant = d.get("window_size", window_size)
	if ws is Vector2i:
		set_window_size(ws)
	set_render_scale(_float(d.get("render_scale"), render_scale))
	set_upscaler(_int(d.get("upscaler"), upscaler))
	set_vsync(_int(d.get("vsync"), vsync))
	set_max_fps(_int(d.get("max_fps"), max_fps))
	var ms: Variant = d.get("motion_smoothing", motion_smoothing)
	motion_smoothing = ms if ms is bool else motion_smoothing
	set_shadow_quality(_int(d.get("shadow_quality"), shadow_quality))
	set_ui_scale(_float(d.get("ui_scale"), ui_scale))


# --- validating setters --------------------------------------------------------

## Out-of-range values fall back to the Tuning.video default.
func set_window_mode(m: int) -> void:
	window_mode = m if m >= 0 and m < WindowMode.size() else Tuning.video.default_window_mode


## Any size at least Tuning.video.window_size_min (the screen clamp happens
## at apply time, see fit_window_size).
func set_window_size(s: Vector2i) -> void:
	window_size = s.max(Tuning.video.window_size_min)


## Snaps to the nearest Tuning.video.render_scale_steps entry.
func set_render_scale(v: float) -> void:
	render_scale = _nearest(Tuning.video.render_scale_steps, v)


func set_upscaler(u: int) -> void:
	upscaler = u if u >= 0 and u < Upscaler.size() else Tuning.video.default_upscaler


func set_vsync(v: int) -> void:
	vsync = v if v >= 0 and v < VSync.size() else Tuning.video.default_vsync


## Must be one of Tuning.video.max_fps_options (else the default).
func set_max_fps(f: int) -> void:
	max_fps = f if f in Tuning.video.max_fps_options else Tuning.video.default_max_fps


func set_shadow_quality(q: int) -> void:
	shadow_quality = q if q >= 0 and q < Shadows.size() else Tuning.video.default_shadow_quality


## Snaps to the nearest Tuning.video.ui_scale_steps entry.
func set_ui_scale(v: float) -> void:
	ui_scale = _nearest(Tuning.video.ui_scale_steps, v)


# --- derived ---------------------------------------------------------------------

func is_windowed() -> bool:
	return window_mode == WindowMode.WINDOWED


## The window size to apply on a screen whose usable area is `usable`:
## the stored size clamped to [window_size_min, usable] (usable empty =
## no screen info, e.g. headless: unclamped).
func fit_window_size(usable: Vector2i) -> Vector2i:
	var min_size := Tuning.video.window_size_min
	if usable.x <= 0 or usable.y <= 0:
		return window_size
	return window_size.clamp(min_size.min(usable), usable)


## Window size presets that fit on `usable` (all of them when unknown).
static func presets_for(usable: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in Tuning.video.window_size_presets:
		if usable.x <= 0 or (p.x <= usable.x and p.y <= usable.y):
			out.append(p)
	return out


## Effective 3D scaling mode for a viewport (FSR only below 100%).
func scaling_mode() -> Viewport.Scaling3DMode:
	if render_scale >= 1.0:
		return Viewport.SCALING_3D_MODE_BILINEAR
	match upscaler:
		Upscaler.FSR1:
			return Viewport.SCALING_3D_MODE_FSR
		Upscaler.FSR2:
			return Viewport.SCALING_3D_MODE_FSR2
	return Viewport.SCALING_3D_MODE_BILINEAR


static func _nearest(steps: PackedFloat32Array, v: float) -> float:
	if steps.is_empty():
		return 1.0
	var best := steps[0]
	for s in steps:
		if absf(s - v) < absf(best - v):
			best = s
	return best


static func _int(v: Variant, fallback: int) -> int:
	return v if v is int else fallback


static func _float(v: Variant, fallback: float) -> float:
	return float(v) if v is float or v is int else fallback
