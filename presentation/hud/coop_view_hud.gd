class_name CoopViewHud
extends Control
## Per-view overlay for co-op runs (SPEC.md §7), one per local view, drawn on
## top of that view's SubViewport (same pixel space as its camera):
##   - the view fighter's current target: name + full HP bar + ki gauge
##     (follows target changes)
##   - teammates: small HP/ki panels from the bottom-left corner, with a
##     DOWNED / OUT status
##   - HP pips over every enemy on screen, edge arrows for enemies off screen
##     (no token colouring: enemies give no attack tell)
##   - a revive ring + bleed-out seconds over each downed teammate
##   - a "P2 ULTIMATE" banner when someone other than the view fighter starts
##     an ultimate (that fighter's own view plays the camera cinematic)
## Enemies and teammates are read from director.fighters every frame, so
## fighters spawned or removed mid-match need no bookkeeping. Read only.

var director: MatchDirector
var fighter: Fighter
var camera: FighterCamera

var _font: SystemFont
var _target_name: Label
var _target_bar: HudHealthBar
var _target_ki: HudKiGauge
var _shown_target: Fighter
var _partners: Array[Dictionary] = []  # {fighter, name, health, ki, status}
var _partner_slots: Array[int] = []
var _banner: Label
var _banner_tween: Tween
## Enemy slots that drew a pip / an edge arrow on the last redraw (tests).
var _pip_slots: Array[int] = []
var _arrow_slots: Array[int] = []


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

	_target_name = _label(t.coop_small_font_size, t.text_color)
	_target_name.name = "TargetName"
	_target_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_target_name)
	_target_bar = HudHealthBar.new()
	_target_bar.name = "TargetHealth"
	add_child(_target_bar)
	_target_ki = HudKiGauge.new()
	_target_ki.name = "TargetKi"
	_target_ki.bars = Tuning.fighter.ki_bars
	add_child(_target_ki)

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


func shown_target() -> Fighter:
	return _shown_target if _valid(_shown_target) else null


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
	var x0 := (w - t.coop_target_width) * 0.5
	_target_name.position = Vector2(x0, t.coop_target_top - t.coop_small_font_size - 10.0)
	_target_name.size = Vector2(t.coop_target_width, t.coop_small_font_size + 8.0)
	_target_bar.position = Vector2(x0, t.coop_target_top)
	_target_bar.size = Vector2(t.coop_target_width, t.coop_target_bar_height)
	_target_ki.position = Vector2(x0, t.coop_target_top + t.coop_target_bar_height + 6.0)
	_target_ki.size = Vector2(t.coop_target_width * t.ki_width_ratio, t.coop_target_ki_height)
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
	_update_target()
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


func _update_target() -> void:
	var tgt := fighter.target if _valid(fighter.target) else null
	var show := tgt != null and not tgt.is_ko()
	_target_name.visible = show
	_target_bar.visible = show
	_target_ki.visible = show
	if not show:
		_shown_target = null
		return
	if tgt != _shown_target:
		_shown_target = tgt
		var char_name := ""
		if tgt.def != null:
			char_name = tgt.def.display_name if tgt.def.display_name != "" else String(tgt.def.id)
		_target_name.text = "%s  %s" % [_tag(tgt), char_name.to_upper()]
		_target_bar.set_ratio(tgt.health_ratio(), true)
	else:
		_target_bar.set_ratio(tgt.health_ratio())
	_target_ki.set_ki(tgt.ki, _ki_max(tgt))


# --- world markers (pips, arrows, revive rings) --------------------------------

func _draw() -> void:
	_pip_slots.clear()
	_arrow_slots.clear()
	if camera == null or not is_instance_valid(camera) or not camera.is_inside_tree() or not _valid(fighter):
		return
	var t := Tuning.hud
	var rect := Rect2(Vector2.ZERO, size)
	for e in enemies():
		if e.is_ko() or e.is_vanished():
			continue
		var pos := SmoothedVisual.render_transform_of(e).origin + Vector3.UP * t.pip_world_height
		if not camera.is_position_behind(pos):
			var p := camera.unproject_position(pos)
			if rect.has_point(p):
				_draw_pip(p, e)
				_pip_slots.append(e.slot)
				continue
		_draw_edge_arrow(pos)
		_arrow_slots.append(e.slot)
	for m in teammates():
		if m.is_downed():
			var pos := SmoothedVisual.render_transform_of(m).origin + Vector3.UP * t.revive_marker_height
			if not camera.is_position_behind(pos):
				_draw_revive_ring(camera.unproject_position(pos), m)


func _draw_pip(at: Vector2, e: Fighter) -> void:
	var t := Tuning.hud
	var r := Rect2(at - Vector2(t.enemy_pip_width * 0.5, t.enemy_pip_height), Vector2(t.enemy_pip_width, t.enemy_pip_height))
	draw_rect(r.grow(1.0), t.outline_color)
	draw_rect(r, t.enemy_pip_bg_color)
	var fill := r
	fill.size.x *= clampf(e.health_ratio(), 0.0, 1.0)
	draw_rect(fill, t.enemy_pip_target_color if e == fighter.target else t.enemy_pip_color)


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
