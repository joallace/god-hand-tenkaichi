class_name VideoTuning
extends Resource
## Video/display defaults and option lists (presentation only; never read by
## the sim). The player's choices live in user://video.cfg (VideoSettings);
## this resource holds what they default to and what the menus offer.
## Edit data/tuning/video.tres.

@export_group("Defaults")
## VideoSettings.WindowMode: 0 windowed, 1 borderless fullscreen, 2 exclusive.
@export var default_window_mode: int = 0
@export var default_window_size: Vector2i = Vector2i(1280, 720)
@export var default_render_scale: float = 1.0
## VideoSettings.Upscaler: 0 bilinear, 1 FSR 1.0, 2 FSR 2.2.
@export var default_upscaler: int = 1
## VideoSettings.VSync: 0 off, 1 on, 2 adaptive.
@export var default_vsync: int = 1
## Frames per second cap, 0 = unlimited.
@export var default_max_fps: int = 0
@export var default_motion_smoothing: bool = true
## VideoSettings.Shadows: 0 off, 1 low, 2 high.
@export var default_shadow_quality: int = 2
@export var default_ui_scale: float = 1.0

@export_group("Options")
## Window size presets offered in windowed mode (sizes larger than the
## screen's usable area are hidden).
@export var window_size_presets: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160),
]
@export var window_size_min: Vector2i = Vector2i(640, 360)
## Custom width/height stepper increments (normal, held for a while).
@export var window_size_step: int = 8
@export var window_size_step_fast: int = 80
## 3D render scale choices (fraction of the view's native pixels).
@export var render_scale_steps: PackedFloat32Array = [0.5, 0.59, 0.67, 0.77, 0.87, 1.0]
@export var fsr_sharpness: float = 0.2
## Max FPS choices; 0 = unlimited.
@export var max_fps_options: PackedInt32Array = [60, 120, 144, 165, 240, 0]
@export var ui_scale_steps: PackedFloat32Array = [0.75, 0.85, 1.0, 1.15, 1.25, 1.5]

@export_group("Shadows")
## Directional shadow atlas size per quality (index = Shadows; off unused).
@export var shadow_atlas_sizes: PackedInt32Array = [0, 2048, 4096]
## RenderingServer.ShadowQuality per quality (index = Shadows; off unused).
@export var shadow_filter_quality: PackedInt32Array = [0, 1, 2]

@export_group("Apply")
## Seconds a display change (window mode / size) waits after the last edit
## before it is applied; input on the display rows (or a field being typed
## in) restarts the wait, so setting width and height applies once.
@export var display_apply_delay: float = 3.0
## "Keep these display settings?" countdown before reverting.
@export var revert_seconds: float = 10.0

@export_group("Motion smoothing")
## A visual that moved further than this (m) in one sim tick snaps instead of
## blending (teleport, vanish, round reset, respawn).
@export var smoothing_snap_distance: float = 1.5
