class_name HudHealthBar
extends Control
## Slanted health bar with a delayed red "damage trail". `mirrored` flips it
## for the right-hand player (drains toward the outer screen edge).

var mirrored := false
var ratio := 1.0
var trail := 1.0
var _trail_wait := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_ratio(r: float, instant: bool = false) -> void:
	r = clampf(r, 0.0, 1.0)
	if instant or r > trail:
		trail = r
	elif r < ratio:
		_trail_wait = Tuning.hud.health_trail_delay
	ratio = r
	queue_redraw()


func _process(delta: float) -> void:
	if trail > ratio:
		if _trail_wait > 0.0:
			_trail_wait -= delta
		else:
			trail = maxf(ratio, trail - Tuning.hud.health_trail_speed * delta)
			queue_redraw()


static func slanted(x0: float, x1: float, h: float, skew: float) -> PackedVector2Array:
	# Left edge vertical (outer), right edge slanted (inner end).
	if x1 - x0 < 0.5:
		return PackedVector2Array()
	var x1b := maxf(x1 - skew, x0)
	return PackedVector2Array([Vector2(x0, 0), Vector2(x1, 0), Vector2(x1b, h), Vector2(x0, h)])


func _draw() -> void:
	var t := Tuning.hud
	var w := size.x
	var h := size.y
	if mirrored:
		draw_set_transform(Vector2(w, 0), 0.0, Vector2(-1, 1))
	var s := t.bar_skew
	_poly(slanted(-3, w + 3, h + 3, s), t.outline_color)
	_poly(slanted(0, w, h, s), t.bar_bg_color)
	if trail > 0.0:
		_poly(slanted(0, w * trail, h, s), t.health_trail_color)
	if ratio > 0.0:
		var c := t.health_low_color.lerp(t.health_high_color, clampf(ratio * 1.6 - 0.3, 0.0, 1.0))
		_poly(slanted(0, w * ratio, h, s), c)
		# glossy highlight
		_poly(slanted(0, maxf(w * ratio - s * 0.6, 0.0), h * 0.35, s * 0.35), Color(1, 1, 1, 0.28))
	var border := slanted(0, w, h, s)
	if border.size() >= 3:
		border.append(border[0])
		draw_polyline(border, t.bar_border_color, 2.0)
	draw_set_transform(Vector2.ZERO)


func _poly(pts: PackedVector2Array, c: Color) -> void:
	if pts.size() >= 3:
		draw_colored_polygon(pts, c)
