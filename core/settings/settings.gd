extends Node
## Autoload "Settings": owns the per-user video and audio settings
## (VideoSettings in user://video.cfg, AudioSettings in user://audio.cfg),
## loads them at boot and applies them. Online settings stay in
## Net.settings and control bindings in Bindings; the Settings screen edits
## all four. Presentation only: nothing here is read by the sim.
##
## apply_video() pushes the video settings to the window (mode, size clamped
## to the current screen, vsync, FPS cap, UI scale), the renderer (shadow
## atlas) and SmoothedVisual, then emits `video_applied`. Per-viewport bits
## (3D render scale + upscaler) are pulled by whoever owns the 3D viewports
## via configure_viewport() (ViewLayout), shadows-on by the Arena.
##
## Headless (tests, tools) the window-level bits are skipped unless
## `apply_display` is set, so a user's video.cfg can't change test layouts.
## On web the browser owns the window: mode, size and vsync are never set
## (PlatformCaps.window_control), the FPS cap and UI scale still apply, and
## the upscaler is always bilinear (PlatformCaps.fsr).

signal video_applied

var video: VideoSettings
var audio: AudioSettings
## Apply window/display settings (off headless; tests may turn it on).
var apply_display := DisplayServer.get_name() != "headless"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	video = VideoSettings.load_from()
	audio = AudioSettings.load_from()
	apply_video()
	audio.apply()


func apply_video() -> void:
	SmoothedVisual.enabled = video.motion_smoothing
	var q := video.shadow_quality
	var t := Tuning.video
	if q != VideoSettings.Shadows.OFF and q < t.shadow_atlas_sizes.size():
		RenderingServer.directional_shadow_atlas_set_size(t.shadow_atlas_sizes[q], true)
		if q < t.shadow_filter_quality.size():
			RenderingServer.directional_soft_shadow_filter_set_quality(
					t.shadow_filter_quality[q] as RenderingServer.ShadowQuality)
	if apply_display:
		var win := get_window()
		Engine.max_fps = video.max_fps
		win.content_scale_factor = video.ui_scale
		if PlatformCaps.window_control():
			DisplayServer.window_set_vsync_mode(_vsync_mode(video.vsync))
			_apply_window(win)
	video_applied.emit()


func apply_audio() -> void:
	audio.apply()


## 3D render scale and upscaler for a viewport that renders the match.
func configure_viewport(vp: Viewport) -> void:
	vp.scaling_3d_mode = video.scaling_mode() if PlatformCaps.fsr() else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = video.render_scale
	vp.fsr_sharpness = Tuning.video.fsr_sharpness


func shadows_enabled() -> bool:
	return video.shadow_quality != VideoSettings.Shadows.OFF


## Usable area of the window's current screen (zero when unknown/headless).
func usable_screen_size() -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return Vector2i.ZERO
	return DisplayServer.screen_get_usable_rect(get_window().current_screen).size


func _apply_window(win: Window) -> void:
	match video.window_mode:
		VideoSettings.WindowMode.BORDERLESS:
			win.mode = Window.MODE_FULLSCREEN
		VideoSettings.WindowMode.FULLSCREEN:
			win.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		_:
			var was_windowed := win.mode == Window.MODE_WINDOWED
			if not was_windowed:
				win.mode = Window.MODE_WINDOWED
			var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
			var size := video.fit_window_size(usable.size)
			if win.size != size or not was_windowed:
				win.size = size
				win.position = usable.position + (usable.size - size) / 2


static func _vsync_mode(v: int) -> DisplayServer.VSyncMode:
	match v:
		VideoSettings.VSync.OFF:
			return DisplayServer.VSYNC_DISABLED
		VideoSettings.VSync.ADAPTIVE:
			return DisplayServer.VSYNC_ADAPTIVE
	return DisplayServer.VSYNC_ENABLED
