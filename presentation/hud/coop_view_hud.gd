class_name CoopViewHud
extends Control
## Per-view overlay for co-op runs (SPEC.md §7), one per local view, drawn on
## top of that view's SubViewport (same pixel space as its camera):
##   - teammates: small HP/ki panels from the bottom-left corner, with a
##     DOWNED / OUT status
##   - an HP bar + ki strip over every enemy on screen (the view fighter's
##     current target in its own colour), edge arrows for enemies off screen
##     (no token colouring: enemies give no attack tell)
##   - a revive ring + bleed-out seconds over each downed teammate
##   - a "P2 ULTIMATE" banner when someone other than the view fighter starts
##     an ultimate (that fighter's own view plays the camera cinematic)
## Enemies and teammates are read from director.fighters every frame, so
## fighters spawned or removed mid-match need no bookkeeping. Read only.
##
## World markers project through the view's camera, whose SubViewport is
## sized in window pixels (ViewLayout._fit) while this overlay is in canvas
## units: `_to_view` rescales between the two.

var director: MatchDirector
var fighter: Fighter
var camera: FighterCamera

var _font: SystemFont
var _partners: Array[Dictionary] = []  # {fighter, name, health, ki, status}
var _partner_slots: Array[int] = []
var _banner: Label
var _banner_tween: Tween
## Enemy slots that drew a pip / an edge arrow on the last redraw (tests).
var _pip_slots: Array[int] = []
var _arrow_slots: Array[int] = []
## slot -> where that enemy's pip was anchored on the last redraw (tests).
var _pip_points: Dictionary = {}
var _target_pip_slot := -1


func _init() -> void:
	name = "CoopViewHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func setup(p_director: MatchDirector, hub: MatchEventHub, p_fighter: Fighter, p_camera: FighterCamera) -> void:
	director = p_director
	fighter = p_fighter
	camera = p_camera
	var t := Tuning.hud
	_font = SystemFont.new()
	_font.font_names = t.font_names
	_font.font_weight = t.font_weight

	_banner = _label(t.banner_font_size, t.banner_color)
	_banner.name = "Banner"
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0
	add_child(_banner)

	resized.connect(_layout)
	if hub != null:
		hub.fighter_event.connect(_on_fighter_event)
	_refresh_partners()
	_layout()


func _label(font_size: int, color: Color) -> Label:
	var t := Tuning.hud
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = _font
	ls.font_size = font_size
	ls.font_color = color
	ls.outline_size = t.outline_size / 2
	ls.outline_color = t.outline_color
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _valid(f: Fighter) -> bool:
	return f != null and is_instance_valid(f) and f.is_inside_tree()


## Fighters on other teams (live), in director order.
func enemies() -> Array[Fighter]:
	var out: Array[Fighter] = []
	if director == null or not _valid(fighter):
		return out
	for f in director.fighters:
		if _valid(f) and f.team != fighter.team:
			out.append(f)
	return out


func teammates() -> Array[Fighter]:
	var out: Array[Fighter] = []
	if director == null or not _valid(fighter):
		return out
	for f in director.fighters:
		if _valid(f) and f != fighter and f.team == fighter.team:
			out.append(f)
	return out


func pip_slots() -> Array[int]:
	return _pip_slots


func arrow_slots() -> Array[int]:
	return _arrow_slots


func pip_point(slot: int) -> Vector2:
	return _pip_points.get(slot, Vector2.INF)


## Slot of the enemy whose pip was drawn as this view's target (-1: none).
func target_pip_slot() -> int:
	return _target_pip_slot


func partner_count() -> int:
	return _partners.size()


func _tag(f: Fighter) -> String:
	if fighter != null and f.team != fighter.team:
		return Tuning.hud.text_enemy_tag
	return MatchHud.slot_tag(director, f.slot)


func _ki_max(f: Fighter) -> float:
	return f.ki_max()


# --- layout / per frame --------------------------------------------------------

func _layout() -> void:
	var t := Tuning.hud
	var w := size.x
	_banner.size = Vector2(w, t.banner_font_size * 1.6)
	_banner.position = Vector2(0, size.y * t.banner_y_ratio - _banner.size.y * 0.5)
	_banner.pivot_offset = _banner.size * 0.5
	for i in _partners.size():
		var p: Dictionary = _partners[i]
		var y := size.y - t.coop_partner_margin - (i + 1) * t.coop_partner_spacing
		var nl: Label = p["name"]
		nl.position = Vector2(t.coop_partner_margin, y)
		nl.size = Vector2(t.coop_partner_width, t.coop_small_font_size + 6.0)
		var hb: HudHealthBar = p["health"]
		hb.position = Vector2(t.coop_partner_margin, y + t.coop_small_font_size + 6.0)
		hb.size = Vector2(t.coop_partner_width, t.coop_partner_bar_height)
		var kg: HudKiGauge = p["ki"]
		kg.position = hb.position + Vector2(0, t.coop_partner_bar_height + 4.0)
		kg.size = Vector2(t.coop_partner_width * t.ki_width_ratio, t.coop_partner_ki_height)
		var st: Label = p["status"]
		st.position = nl.position + Vector2(t.coop_partner_width * 0.5, 0)
		st.size = Vector2(t.coop_partner_width * 0.5, nl.size.y)


func _refresh_partners() -> void:
	var mates := teammates()
	var slots: Array[int] = []
	for m in mates:
		slots.append(m.slot)
	if slots == _partner_slots:
		return
	_partner_slots = slots
	for p in _partners:
		for key in ["name", "health", "ki", "status"]:
			(p[key] as Node).queue_free()
	_partners.clear()
	var t := Tuning.hud
	for m in mates:
		var color := t.slot_color(m.slot)
		var nl := _label(t.coop_small_font_size, color)
		nl.name = "PartnerName%d" % (m.slot + 1)
		nl.text = _tag(m)
		add_child(nl)
		var hb := HudHealthBar.new()
		hb.name = "PartnerHealth%d" % (m.slot + 1)
		hb.set_ratio(m.health_ratio(), true)
		add_child(hb)
		var kg := HudKiGauge.new()
		kg.name = "PartnerKi%d" % (m.slot + 1)
		kg.bars = Tuning.fighter.ki_bars
		add_child(kg)
		var st := _label(t.coop_small_font_size, t.downed_color)
		st.name = "PartnerStatus%d" % (m.slot + 1)
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(st)
		_partners.append({"fighter": m, "name": nl, "health": hb, "ki": kg, "status": st})
	_layout()


func _process(_delta: float) -> void:
	if not _valid(fighter):
		return
	_refresh_partners()
	var t := Tuning.hud
	for p in _partners:
		var m: Fighter = p["fighter"]
		if not _valid(m):
			continue
		(p["health"] as HudHealthBar).set_ratio(m.health_ratio())
		(p["ki"] as HudKiGauge).set_ki(m.ki, _ki_max(m))
		(p["name"] as Label).text = _tag(m)
		var st: Label = p["status"]
		if m.is_out():
			st.text = t.text_out
			st.label_settings.font_color = t.out_color
		elif m.is_downed():
			st.text = t.text_downed
			st.label_settings.font_color = t.downed_color
		else:
			st.text = ""
	queue_redraw()


# --- world markers (pips, arrows, revive rings) --------------------------------

## Camera (SubViewport pixel) position -> this overlay's coordinates.
func _to_view(world_pos: Vector3) -> Vector2:
	var vp_size := camera.get_viewport().get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return Vector2.INF
	return camera.unproject_position(world_pos) * size / vp_size


func _draw() -> void:
	_pip_slots.clear()
	_arrow_slots.clear()
	_pip_points.clear()
	_target_pip_slot = -1
	if camera == null or not is_instance_valid(camera) or not camera.is_inside_tree() or not _valid(fighter):
		return
	var t := Tuning.hud
	var rect := Rect2(Vector2.ZERO, size)
	for e in enemies():
		if e.is_ko() or e.is_vanished():
			continue
		var pos := SmoothedVisual.render_transform_of(e).origin + Vector3.UP * t.pip_world_height
		if not camera.is_position_behind(pos):
			var p := _to_view(pos)
			if rect.has_point(p):
				_draw_pip(p, e)
				_pip_slots.append(e.slot)
				_pip_points[e.slot] = p
				if e == fighter.target:
					_target_pip_slot = e.slot
				continue
		_draw_edge_arrow(pos)
		_arrow_slots.append(e.slot)
	for m in teammates():
		if m.is_downed():
			var pos := SmoothedVisual.render_transform_of(m).origin + Vector3.UP * t.revive_marker_height
			if not camera.is_position_behind(pos):
				_draw_revive_ring(_to_view(pos), m)


## HP bar with a ki strip under it, bottom edge at `at`. The ki strip fills
## like the HUD gauge: full bars bright, the bar being charged dim, a tick
## between bars.
func _draw_pip(at: Vector2, e: Fighter) -> void:
	var t := Tuning.hud
	var w := t.enemy_pip_width
	var total_h := t.enemy_pip_height + t.enemy_pip_ki_gap + t.enemy_pip_ki_height
	var box := Rect2(at - Vector2(w * 0.5, total_h), Vector2(w, total_h))
	draw_rect(box.grow(1.0), t.outline_color)
	var hp := Rect2(box.position, Vector2(w, t.enemy_pip_height))
	draw_rect(hp, t.enemy_pip_bg_color)
	var fill := hp
	fill.size.x *= clampf(e.health_ratio(), 0.0, 1.0)
	draw_rect(fill, t.enemy_pip_target_color if e == fighter.target else t.enemy_pip_color)

	var ki := Rect2(box.position + Vector2(0.0, t.enemy_pip_height + t.enemy_pip_ki_gap), Vector2(w, t.enemy_pip_ki_height))
	draw_rect(ki, t.ki_empty_color)
	var bars := maxi(Tuning.fighter.ki_bars, 1)
	var ki_ratio := clampf(e.ki / maxf(_ki_max(e), 0.0001), 0.0, 1.0)
	var full_w := floorf(ki_ratio * bars + 0.0001) / bars * w
	if full_w > 0.0:
		draw_rect(Rect2(ki.position, Vector2(full_w, ki.size.y)), t.ki_full_color)
	var part_w := ki_ratio * w - full_w
	if part_w > 0.0:
		draw_rect(Rect2(ki.position + Vector2(full_w, 0.0), Vector2(part_w, ki.size.y)), t.ki_partial_color)
	for i in range(1, bars):
		var x := ki.position.x + w * i / bars
		draw_line(Vector2(x, ki.position.y), Vector2(x, ki.end.y), t.outline_color)


func _draw_edge_arrow(world_pos: Vector3) -> void:
	var t := Tuning.hud
	# Direction in camera space: x right, y up (works behind the camera too).
	var local := camera.global_transform.affine_inverse() * world_pos
	var dir := Vector2(local.x, -local.y)
	if dir.length_squared() < 0.0001:
		dir = Vector2.DOWN
	dir = dir.normalized()
	var half := size * 0.5
	var lim := (half - Vector2.ONE * t.edge_arrow_inset).max(Vector2.ONE)
	var k := INF
	if absf(dir.x) > 0.0001:
		k = minf(k, lim.x / absf(dir.x))
	if absf(dir.y) > 0.0001:
		k = minf(k, lim.y / absf(dir.y))
	var tip := half + dir * k
	var side := Vector2(-dir.y, dir.x) * t.edge_arrow_size * 0.6
	var base := tip - dir * t.edge_arrow_size
	draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), t.edge_arrow_color)


func _draw_revive_ring(at: Vector2, m: Fighter) -> void:
	var t := Tuning.hud
	draw_arc(at, t.revive_ring_radius, 0.0, TAU, t.revive_arc_points, t.revive_ring_bg_color, t.revive_ring_width)
	var prog := clampf(m.revive_progress(), 0.0, 1.0)
	if prog > 0.0:
		draw_arc(at, t.revive_ring_radius, -PI * 0.5, -PI * 0.5 + TAU * prog, t.revive_arc_points,
				t.revive_ring_color, t.revive_ring_width)
	var left := (1.0 - clampf(m.bleed_out_ratio(), 0.0, 1.0)) * Tuning.coop.bleed_out_frames / float(Tuning.match_rules.tick_rate)
	var text := t.text_bleed_out % ceili(left)
	var fs := t.coop_small_font_size
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, at + Vector2(-tw * 0.5, fs * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, t.downed_color)


# --- events --------------------------------------------------------------------

func _on_fighter_event(f: Fighter, kind: StringName, _data: Dictionary) -> void:
	if kind == &"ultimate_start" and _valid(fighter) and f != fighter:
		show_banner(Tuning.hud.text_ultimate_banner % _tag(f))


func show_banner(text: String) -> void:
	var t := Tuning.hud
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner.text = text
	_banner.modulate.a = 1.0
	_banner.scale = Vector2.ONE * 1.3
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, t.announce_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_interval(t.banner_hold)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, t.announce_out)


func banner_text() -> String:
	return _banner.text if _banner.modulate.a > 0.0 else ""
