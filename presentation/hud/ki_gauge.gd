class_name HudKiGauge
extends Control
## Segmented ki gauge: `bars` slanted segments, each partially filled.
## `mirrored` flips it for the right-hand player.

var mirrored := false
var bars := 5
var ki := 0.0
var ki_max := 500.0
var _denied := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_ki(value: float, max_value: float) -> void:
	ki = value
	if max_value > 0.0:
		ki_max = max_value
	queue_redraw()


func full_bars() -> int:
	return int(floor(ki / maxf(ki_max / bars, 0.0001) + 0.0001))


func flash_denied() -> void:
	_denied = Tuning.hud.ki_denied_flash
	queue_redraw()


func _process(delta: float) -> void:
	if _denied > 0.0:
		_denied -= delta
		queue_redraw()


func _draw() -> void:
	var t := Tuning.hud
	var w := size.x
	var h := size.y
	if mirrored:
		draw_set_transform(Vector2(w, 0), 0.0, Vector2(-1, 1))
	var gap := t.ki_segment_gap
	var seg_w := (w - gap * (bars - 1)) / bars
	var bar_size := ki_max / bars
	var s := t.bar_skew * 0.5
	var deny := clampf(_denied / maxf(t.ki_denied_flash, 0.001), 0.0, 1.0)
	for i in bars:
		var x0 := i * (seg_w + gap)
		var fill := clampf((ki - i * bar_size) / bar_size, 0.0, 1.0)
		var base := _para(x0, x0 + seg_w, h, s)
		var outline := _para(x0 - 2, x0 + seg_w + 2, h + 2, s)
		draw_colored_polygon(outline, t.outline_color)
		draw_colored_polygon(base, t.ki_empty_color.lerp(t.ki_denied_color, deny * 0.8))
		if fill * seg_w > 0.5:
			var c := t.ki_full_color if fill >= 1.0 else t.ki_partial_color
			draw_colored_polygon(_para(x0, x0 + seg_w * fill, h, s * fill), c)
			if fill >= 1.0:
				draw_colored_polygon(_para(x0, x0 + seg_w, h * 0.35, s * 0.35), Color(1, 1, 1, 0.35))
	draw_set_transform(Vector2.ZERO)


static func _para(x0: float, x1: float, h: float, s: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0 + s, 0), Vector2(x1 + s, 0), Vector2(x1, h), Vector2(x0, h)])
