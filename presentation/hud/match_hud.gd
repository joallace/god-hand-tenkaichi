class_name MatchHud
extends CanvasLayer
## Global match HUD drawn once over all views: P1 on the left, P2 on the
## right, timer in the center. Per player: name, round-win pips, health bar
## with damage trail, segmented ki gauge (+ full bar count), combo popup and
## a callout line (GUARD CRASH / THROW BREAK / COUNTER).
## Center: timer ("∞" when infinite) and announcer text (ROUND / FIGHT! /
## K.O. / TIME / DRAW / winner). Purely signal driven.

const LAYER := 10

var director: MatchDirector
var root: Control
var announcer: Label
var timer_label: Label
var panels: Dictionary = {}  # slot -> Dictionary of widgets

var _announce_tween: Tween
var _font: SystemFont


func _init() -> void:
	name = "MatchHud"
	layer = LAYER


func setup(p_director: MatchDirector, hub: MatchEventHub) -> void:
	director = p_director
	_font = SystemFont.new()
	_font.font_names = Tuning.hud.font_names
	_font.font_weight = Tuning.hud.font_weight

	root = Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.resized.connect(_layout)

	timer_label = _label(Tuning.hud.timer_font_size, Tuning.hud.text_color)
	timer_label.name = "Timer"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(timer_label)

	announcer = _label(Tuning.hud.announce_font_size, Tuning.hud.announce_color)
	announcer.name = "Announcer"
	announcer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	announcer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	announcer.modulate.a = 0.0
	root.add_child(announcer)

	director.fighters_spawned.connect(_on_fighters_spawned)
	director.round_started.connect(_on_round_started)
	director.phase_changed.connect(_on_phase_changed)
	director.round_ended.connect(_on_round_ended)
	director.match_ended.connect(_on_match_ended)
	director.timer_changed.connect(_on_timer_changed)
	if hub != null:
		hub.fighter_event.connect(_on_fighter_event)


func _label(font_size: int, color: Color) -> Label:
	var t := Tuning.hud
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = _font
	ls.font_size = font_size
	ls.font_color = color
	ls.outline_size = t.outline_size
	ls.outline_color = t.outline_color
	ls.shadow_size = 2
	ls.shadow_color = Color(0, 0, 0, 0.5)
	ls.shadow_offset = Vector2(3, 3)
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# --- player panels -------------------------------------------------------------

func _on_fighters_spawned(fighters: Array[Fighter]) -> void:
	for i in fighters.size():
		_build_panel(fighters[i], i % 2 == 1)
	_layout()


func _build_panel(f: Fighter, right_side: bool) -> void:
	var t := Tuning.hud
	var pcolor := t.p1_color if f.slot % 2 == 0 else t.p2_color
	var p := {"fighter": f, "right": right_side}

	var name_label := _label(t.name_font_size, pcolor)
	name_label.name = "Name%d" % (f.slot + 1)
	var char_name := ""
	var tag := "P%d" % (f.slot + 1)
	if director.config != null:
		tag = director.config.player_tag(f.slot)
		for pc in director.config.players:
			if pc.slot == f.slot:
				char_name = String(pc.character_id).to_upper()
	name_label.text = "%s  %s" % [tag, char_name] if not right_side else "%s  %s" % [char_name, tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right_side else HORIZONTAL_ALIGNMENT_LEFT
	root.add_child(name_label)
	p["name"] = name_label

	var hb := HudHealthBar.new()
	hb.name = "Health%d" % (f.slot + 1)
	hb.mirrored = right_side
	hb.set_ratio(f.health_ratio(), true)
	root.add_child(hb)
	p["health"] = hb

	var kg := HudKiGauge.new()
	kg.name = "Ki%d" % (f.slot + 1)
	kg.mirrored = right_side
	kg.bars = Tuning.fighter.ki_bars
	kg.set_ki(f.ki, _ki_max(f))
	root.add_child(kg)
	p["ki"] = kg

	var ki_count := _label(int(t.name_font_size * 1.1), t.ki_full_color)
	ki_count.name = "KiCount%d" % (f.slot + 1)
	ki_count.text = str(kg.full_bars())
	ki_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(ki_count)
	p["ki_count"] = ki_count

	var pips := HBoxContainer.new()
	pips.name = "Pips%d" % (f.slot + 1)
	pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pips.add_theme_constant_override("separation", 6)
	pips.alignment = BoxContainer.ALIGNMENT_BEGIN if right_side else BoxContainer.ALIGNMENT_END
	var rtw := director.config.rounds_to_win if director.config != null else 2
	for i in rtw:
		var pip := Panel.new()
		pip.custom_minimum_size = Vector2.ONE * t.pip_size
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_theme_stylebox_override("panel", _pip_style(false))
		pips.add_child(pip)
	root.add_child(pips)
	p["pips"] = pips

	var combo := _label(t.combo_font_size, t.text_color)
	combo.name = "Combo%d" % (f.slot + 1)
	combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right_side else HORIZONTAL_ALIGNMENT_LEFT
	combo.modulate.a = 0.0
	root.add_child(combo)
	p["combo"] = combo
	p["combo_tween"] = null

	var callout := _label(t.callout_font_size, t.text_color)
	callout.name = "Callout%d" % (f.slot + 1)
	callout.horizontal_alignment = combo.horizontal_alignment
	callout.modulate.a = 0.0
	root.add_child(callout)
	p["callout"] = callout
	p["callout_tween"] = null

	panels[f.slot] = p
	f.health_changed.connect(_on_health_changed.bind(f.slot))
	f.ki_changed.connect(_on_ki_changed.bind(f.slot))
	f.combo_changed.connect(_on_combo_changed.bind(f.slot))


func _pip_style(won: bool) -> StyleBoxFlat:
	var t := Tuning.hud
	var sb := StyleBoxFlat.new()
	sb.bg_color = t.pip_won_color if won else t.pip_empty_color
	sb.set_corner_radius_all(int(t.pip_size))
	sb.set_border_width_all(2)
	sb.border_color = t.outline_color
	return sb


func _ki_max(f: Fighter) -> float:
	if f.has_method("ki_max"):
		return float(f.call("ki_max"))
	return Tuning.fighter.ki_bar_size * Tuning.fighter.ki_bars


func _layout() -> void:
	if root == null:
		return
	var t := Tuning.hud
	var w := root.size.x
	var h := root.size.y
	var bar_w := maxf((w - 2.0 * t.side_margin - t.center_gap) * 0.5, 50.0)
	var name_h := t.name_font_size + 8.0
	var bar_y := t.top_margin + name_h
	var ki_y := bar_y + t.health_bar_height + 8.0
	var ki_w := bar_w * t.ki_width_ratio

	timer_label.position = Vector2(w * 0.5 - t.center_gap * 0.5, t.top_margin)
	timer_label.size = Vector2(t.center_gap, t.timer_font_size + 16.0)
	announcer.size = Vector2(w, t.announce_font_size * 1.6)
	announcer.position = Vector2(0, h * 0.36 - announcer.size.y * 0.5)
	announcer.pivot_offset = announcer.size * 0.5

	for slot: int in panels:
		var p: Dictionary = panels[slot]
		var right: bool = p["right"]
		var x0 := w * 0.5 + t.center_gap * 0.5 if right else t.side_margin
		var hb: HudHealthBar = p["health"]
		hb.position = Vector2(x0, bar_y)
		hb.size = Vector2(bar_w, t.health_bar_height)
		var nl: Label = p["name"]
		nl.position = Vector2(x0, t.top_margin - 4.0)
		nl.size = Vector2(bar_w, name_h)
		var pips: HBoxContainer = p["pips"]
		pips.size = Vector2(bar_w * 0.4, t.pip_size)
		pips.position = Vector2(x0 if right else x0 + bar_w - pips.size.x, t.top_margin + name_h * 0.5 - t.pip_size * 0.5)
		if right:
			pips.position.x += t.bar_skew + 4.0
		else:
			pips.position.x -= t.bar_skew + 4.0
		var kg: HudKiGauge = p["ki"]
		kg.size = Vector2(ki_w, t.ki_bar_height)
		kg.position = Vector2(x0 + bar_w - ki_w if right else x0, ki_y)
		var kc: Label = p["ki_count"]
		kc.size = Vector2(40, t.ki_bar_height + 20)
		var kc_x := kg.position.x - 46.0 if right else kg.position.x + ki_w + 6.0
		kc.position = Vector2(kc_x, ki_y - 12.0)
		var combo: Label = p["combo"]
		combo.size = Vector2(bar_w, t.combo_font_size + 20.0)
		combo.position = Vector2(x0, ki_y + t.ki_bar_height + 24.0)
		combo.pivot_offset = Vector2(combo.size.x if right else 0.0, combo.size.y * 0.5)
		var callout: Label = p["callout"]
		callout.size = Vector2(bar_w, t.callout_font_size + 16.0)
		callout.position = Vector2(x0, combo.position.y + combo.size.y)
		callout.pivot_offset = Vector2(callout.size.x if right else 0.0, callout.size.y * 0.5)


# --- fighter signals -----------------------------------------------------------

func _on_health_changed(value: float, max_value: float, slot: int) -> void:
	var hb: HudHealthBar = panels[slot]["health"]
	var r := value / max_value if max_value > 0.0 else 0.0
	hb.set_ratio(r, director.phase == MatchDirector.Phase.INTRO or r >= hb.ratio)


func _on_ki_changed(value: float, max_value: float, slot: int) -> void:
	var kg: HudKiGauge = panels[slot]["ki"]
	kg.set_ki(value, max_value)
	(panels[slot]["ki_count"] as Label).text = str(kg.full_bars())


func _on_combo_changed(hits: int, slot: int) -> void:
	var t := Tuning.hud
	var p: Dictionary = panels[slot]
	var combo: Label = p["combo"]
	var old: Variant = p["combo_tween"]
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
	var tw := create_tween()
	if hits >= t.combo_min_hits:
		combo.text = t.text_combo % hits
		combo.modulate.a = 1.0
		combo.scale = Vector2.ONE * 1.5
		tw.tween_property(combo, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_interval(t.combo_linger * 2.0)
		tw.tween_property(combo, "modulate:a", 0.0, 0.3)
	else:
		tw.tween_interval(t.combo_linger)
		tw.tween_property(combo, "modulate:a", 0.0, 0.3)
	p["combo_tween"] = tw


func _on_fighter_event(f: Fighter, kind: StringName, _data: Dictionary) -> void:
	if not panels.has(f.slot):
		return
	var t := Tuning.hud
	match kind:
		&"not_enough_ki":
			(panels[f.slot]["ki"] as HudKiGauge).flash_denied()
		&"guard_break":
			callout(f.slot, t.text_guard_crash, t.guard_crash_color)
		&"throw_break":
			callout(f.slot, t.text_throw_break, t.throw_break_color)
		&"counter_guard":
			callout(f.slot, t.text_counter, t.counter_color)


## Brief text under a player's combo counter (shown on the emitter's side).
func callout(slot: int, text: String, color: Color) -> void:
	var t := Tuning.hud
	var p: Dictionary = panels[slot]
	var l: Label = p["callout"]
	var old: Variant = p["callout_tween"]
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
	l.text = text
	l.label_settings.font_color = color
	l.modulate.a = 1.0
	l.scale = Vector2.ONE * 1.4
	var tw := create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, t.announce_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(t.callout_hold)
	tw.tween_property(l, "modulate:a", 0.0, t.callout_fade)
	p["callout_tween"] = tw


# --- director signals ----------------------------------------------------------

func _on_timer_changed(seconds_left: int) -> void:
	var t := Tuning.hud
	if seconds_left < 0:
		timer_label.text = t.text_infinite
		timer_label.label_settings.font_color = t.text_color
	else:
		timer_label.text = str(seconds_left)
		timer_label.label_settings.font_color = t.ko_color if seconds_left <= 10 else t.text_color


func _on_round_started(round_number: int) -> void:
	var t := Tuning.hud
	_refresh_pips()
	var is_final := false
	if director.config != null and director.config.rounds_to_win > 1:
		is_final = true
		for w in director.wins:
			if w < director.config.rounds_to_win - 1:
				is_final = false
	announce(t.text_final_round if is_final else t.text_round % round_number, t.announce_color, t.announce_hold)


func _on_phase_changed(phase: MatchDirector.Phase) -> void:
	if phase == MatchDirector.Phase.FIGHT:
		announce(Tuning.hud.text_fight, Tuning.hud.announce_color, Tuning.hud.announce_hold * 0.7)


func _on_round_ended(winner_slot: int, reason: StringName) -> void:
	var t := Tuning.hud
	_refresh_pips()
	var text := t.text_ko
	match reason:
		&"time": text = t.text_time
		&"draw": text = t.text_draw
	announce(text, t.ko_color, t.round_result_delay)
	if winner_slot >= 0:
		get_tree().create_timer(t.round_result_delay + t.announce_out, false).timeout.connect(
				_announce_round_winner.bind(winner_slot))


func _announce_round_winner(winner_slot: int) -> void:
	if director.phase == MatchDirector.Phase.OUTRO:
		announce(Tuning.hud.text_round_winner % (winner_slot + 1), _slot_color(winner_slot), Tuning.hud.announce_hold)


func _on_match_ended(winner_slot: int) -> void:
	var t := Tuning.hud
	announce(t.text_match_winner % (winner_slot + 1), _slot_color(winner_slot), -1.0)


func _slot_color(slot: int) -> Color:
	return Tuning.hud.p1_color if slot % 2 == 0 else Tuning.hud.p2_color


func _refresh_pips() -> void:
	for slot: int in panels:
		var pips: HBoxContainer = panels[slot]["pips"]
		var won := director.wins[slot] if slot < director.wins.size() else 0
		var n := pips.get_child_count()
		for i in n:
			# Fill from the inner (center) side.
			var idx := n - 1 - i if not panels[slot]["right"] else i
			(pips.get_child(idx) as Panel).add_theme_stylebox_override("panel", _pip_style(i < won))


## Big center text. hold < 0 = stay until replaced.
func announce(text: String, color: Color, hold: float) -> void:
	var t := Tuning.hud
	if _announce_tween != null and _announce_tween.is_valid():
		_announce_tween.kill()
	announcer.text = text
	announcer.label_settings.font_color = color
	announcer.modulate.a = 0.0
	announcer.scale = Vector2.ONE * 2.2
	_announce_tween = create_tween()
	_announce_tween.set_parallel()
	_announce_tween.tween_property(announcer, "modulate:a", 1.0, t.announce_in)
	_announce_tween.tween_property(announcer, "scale", Vector2.ONE, t.announce_in).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if hold >= 0.0:
		_announce_tween.chain().tween_interval(hold)
		_announce_tween.chain().tween_property(announcer, "modulate:a", 0.0, t.announce_out)
