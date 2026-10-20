class_name SmoothedVisual
extends Node3D
## Motion smoothing for a sim entity's visuals (presentation only). Add as a
## child of the sim Node3D and put the meshes under it: it is top_level and
## follows its parent's transform, blended between the last two sim ticks by
## Engine.get_physics_interpolation_fraction(), so fighters and projectiles
## move smoothly on displays faster than the 60 Hz tick. The sim itself and
## the engine's physics interpolation setting are untouched.
##
## - Records the parent's transform once per physics frame, after every sim
##   _physics_process (RECORD_PRIORITY), so a rollback resim inside that
##   frame just becomes the new target: corrections blend over one tick.
## - A move longer than Tuning.video.smoothing_snap_distance in one tick
##   (teleport, vanish, round reset) snaps. Respawned entities (rollback
##   load_state recreates nodes) start snapped in _enter_tree.
## - Draws up to one tick behind the sim (the price of blending); with
##   `enabled` false (Settings > Graphics > Motion smoothing: Off) it draws
##   the raw sim transform.
## - Anything that frames or tracks an entity on screen (cameras, HUD
##   markers) should read render_transform_of() instead of global_transform.

## Mirrors Settings.video.motion_smoothing (set by Settings.apply_video).
static var enabled := true

## Physics priority: after the director / rollback driver step the sim.
const RECORD_PRIORITY := 1 << 20

var _src: Node3D
var _prev := Transform3D.IDENTITY
var _cur := Transform3D.IDENTITY


func _enter_tree() -> void:
	_src = get_parent() as Node3D
	top_level = true
	process_physics_priority = RECORD_PRIORITY
	snap()


## Forget the history and draw the parent's current transform.
func snap() -> void:
	if _src == null or not _src.is_inside_tree():
		return
	_cur = _src.global_transform
	_prev = _cur
	global_transform = _cur


func _physics_process(_delta: float) -> void:
	record()


## Take the parent's transform as the newest tick (public for tests).
func record() -> void:
	if _src == null or not _src.is_inside_tree():
		return
	var t := _src.global_transform
	_prev = t if t.origin.distance_to(_cur.origin) > Tuning.video.smoothing_snap_distance else _cur
	_cur = t


## The transform to draw at blend `fraction` (0 = previous tick, 1 = newest).
func transform_at(fraction: float) -> Transform3D:
	if not enabled:
		return _src.global_transform if _src != null and _src.is_inside_tree() else _cur
	return _prev.interpolate_with(_cur, clampf(fraction, 0.0, 1.0))


func render_transform() -> Transform3D:
	return transform_at(Engine.get_physics_interpolation_fraction())


func _process(_delta: float) -> void:
	global_transform = render_transform()


## The SmoothedVisual child of `node`, or null.
static func of(node: Node) -> SmoothedVisual:
	if node == null:
		return null
	for c in node.get_children():
		if c is SmoothedVisual:
			return c
	return null


## Where `node` is drawn this frame (its smoothed visual if it has one).
static func render_transform_of(node: Node3D) -> Transform3D:
	var v := of(node)
	return v.render_transform() if v != null else node.global_transform
