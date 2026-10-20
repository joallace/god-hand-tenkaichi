class_name MatchHud
extends CanvasLayer
## Global match HUD drawn once over all views: P1 on the left, P2 on the
## right, timer in the center. Versus with 3-4 fighters (panel_places):
## two teams -> the lowest slot's team on the left, the other on the right,
## teammates stacked in compact rows; FFA / 3+ teams -> sides alternate in
## slot order, the 3rd / 4th fighter on a second compact row. Pips show the
## panel's team wins; a team of 2+ wins as "P1 & P3 WIN". Per player: name, round-win pips, health bar
## with damage trail, segmented ki gauge (+ full bar count), combo popup and
## a callout line (GUARD CRASH / THROW BREAK / COUNTER).
## Center: timer ("∞" when infinite) and announcer text (ROUND / FIGHT! /
## K.O. / TIME / DRAW / winner).
##
## Inputs (MatchEventHub streams, SPEC_ONLINE.md §9): callouts / ki denied
## flashes and FIGHT! from the immediate stream; round / match / run / wave
## announcements (and pips, wave counter) only from the confirmed stream, so
## a rolled-back KO is never announced; timer and enemies-left are read from
## sim state every frame; health / ki / combo from the fighters' own signals
## (re-sent by Fighter.load_state, so they follow a rollback).
##
## Co-op (config.mode == COOP): panels only for the first two team-0 fighters
## (humans / ally; enemies get per-view pips and a target bar from
## CoopViewHud), no round pips or round announcements, the run timer is
## hidden when infinite, an "ENEMIES n" counter sits under it
## (CoopRun.enemies_left()) and run_ended
## announces CLEARED / WIPED OUT. Waves runs add a "WAVE n / N" counter under
## it, announce each wave (WAVE n / FINAL WAVE; the first during the intro,
## before FIGHT!) and WAVE CLEAR! at the start of each breather.
##
## Online (the match scene feeds these, SPEC_ONLINE.md §7.1, §10.3, §13):
## a "⏸ <name>" tag under the panel of every slot whose peer has the pause
## overlay open (`set_paused_peers`; peers without a panel are listed under
## the waiting banner), the "Waiting for <name>…" banner (`set_waiting`),
## short notices ("<name> disconnected", `notice`), and winner texts that use
## the players' names.

const LAYER := 10

var director: MatchDirector
var root: Control
var announcer: Label
var timer_label: Label
## Co-op only: enemies left in the run.
var enemies_label: Label
## Co-op Waves only: current wave.
var wave_label: Label
var panels: Dictionary = {}  # slot -> Dictionary of widgets
## Online: "Waiting for <name>…" (hidden when not stalled).
var waiting_label: Label
## Online: paused peers that have no panel of their own.
var pause_list_label: Label
## Online: brief notices ("<name> disconnected").
var notice_label: Label

var _announce_tween: Tween
var _notice_tween: Tween
var _paused_peers: Array[int] = []
var _font: SystemFont
var _shown_seconds := -2
var _shown_enemies := -1


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

	var t := Tuning.hud
	waiting_label = _label(t.waiting_font_size, t.waiting_color)
	waiting_label.name = "Waiting"
	waiting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	waiting_label.visible = false
	root.add_child(waiting_label)
	pause_list_label = _label(t.pause_tag_font_size, t.pause_tag_color)
	pause_list_label.name = "PausedPeers"
	pause_list_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_list_label.visible = false
	root.add_child(pause_list_label)
	notice_label = _label(t.notice_font_size, t.notice_color)
	notice_label.name = "Notice"
	notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice_label.modulate.a = 0.0
	root.add_child(notice_label)

	if hub == null:  # standalone (tests): a private hub, confirming at once
		hub = MatchEventHub.new()
		add_child(hub)
	hub.bind_director(director)
	director.fighters_spawned.connect(_on_fighters_spawned)
	hub.fighter_event.connect(_on_fighter_event)
	hub.director_event.connect(_on_director_event)
	hub.confirmed_event.connect(_on_confirmed_event)


## Co-op widgets. Built when the fighters spawn: the director only gets its
## config in setup(), which runs after the HUD's setup.
func _build_coop() -> void:
	if enemies_label == null:
		enemies_label = _label(Tuning.hud.enemies_left_font_size, Tuning.hud.text_color)
		enemies_label.name = "EnemiesLeft"
		enemies_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(enemies_label)
		_sync_state()
	if wave_label == null and director.coop != null and director.coop.is_waves():
		wave_label = _label(Tuning.hud.enemies_left_font_size, Tuning.hud.text_color)
		wave_label.name = "Wave"
		wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(wave_label)


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

func _coop() -> bool:
	return director != null and director.config != null and director.config.mode == MatchConfig.Mode.COOP


func _on_fighters_spawned(fighters: Array[Fighter]) -> void:
	if _coop():
		_build_coop()
		var team0: Array[Fighter] = []
		for f in fighters:
			if f.team == 0:
				team0.append(f)
		team0.sort_custom(func(a: Fighter, b: Fighter) -> bool: return a.slot < b.slot)
		for i in mini(team0.size(), 2):
			_build_panel(team0[i], i == 1)
	else:
		var places := panel_places(fighters)
		var compact := false
		for place: Vector2i in places.values():
			compact = compact or place.y > 0
		for f in fighters:
			var place: Vector2i = places[f.slot]
			_build_panel(f, place.x == 1, place.y, compact)
	_layout()
	_refresh_pause_tags()


## Versus panel spots: slot -> Vector2i(side: 0 left / 1 right, row).
## Exactly two teams: the lowest slot's team on the left, the other team on
## the right, teammates in rows by slot. Otherwise (FFA, 3+ teams): sides
## alternate in slot order, the 3rd / 4th fighter on the second row.
static func panel_places(fighters: Array[Fighter]) -> Dictionary:
	var sorted: Array[Fighter] = fighters.duplicate()
	sorted.sort_custom(func(a: Fighter, b: Fighter) -> bool: return a.slot < b.slot)
	var teams: Array[int] = []  # in order of their lowest slot
	for f in sorted:
		if not f.team in teams:
			teams.append(f.team)
	var out := {}
	if teams.size() == 2:
		var rows: Array[int] = [0, 0]
		for f in sorted:
			var side := 0 if f.team == teams[0] else 1
			out[f.slot] = Vector2i(side, rows[side])
			rows[side] += 1
	else:
		for i in sorted.size():
			@warning_ignore("integer_division")
			out[sorted[i].slot] = Vector2i(i % 2, i / 2)
	return out


## `row` > 0 stacks the panel under the others on its side; `compact` (some
## side has 2+ rows) uses the smaller stack_* sizes for every panel.
func _build_panel(f: Fighter, right_side: bool, row: int = 0, compact: bool = false) -> void:
	var t := Tuning.hud
	var pcolor := t.slot_color(f.slot)
	var p := {"fighter": f, "right": right_side, "row": row, "compact": compact}

	var name_label := _label(t.stack_name_font_size if compact else t.name_font_size, pcolor)
	name_label.name = "Name%d" % (f.slot + 1)
	var char_name := ""
	var tag := "P%d" % (f.slot + 1)
	if director.config != null:
		tag = director.config.player_tag(f.slot)
		for pc in director.config.players:
			if pc.slot == f.slot:
				char_name = String(pc.character_id).to_upper()
	tag = slot_tag(director, f.slot)
	p["char_name"] = char_name
	p["tag"] = tag
	name_label.text = _name_text(tag, char_name, right_side)
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

	var ki_count := _label(int((t.stack_name_font_size if compact else t.name_font_size) * 1.1), t.ki_full_color)
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
	if _coop():
		rtw = 0  # one run, no rounds
	for i in rtw:
		var pip := Panel.new()
		pip.custom_minimum_size = Vector2.ONE * t.pip_size
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_theme_stylebox_override("panel", _pip_style(false))
		pips.add_child(pip)
	root.add_child(pips)
	p["pips"] = pips

	var combo := _label(t.stack_combo_font_size if compact else t.combo_font_size, t.text_color)
	combo.name = "Combo%d" % (f.slot + 1)
	combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right_side else HORIZONTAL_ALIGNMENT_LEFT
	combo.modulate.a = 0.0
	root.add_child(combo)
	p["combo"] = combo
	p["combo_tween"] = null

	var callout := _label(t.stack_callout_font_size if compact else t.callout_font_size, t.text_color)
	callout.name = "Callout%d" % (f.slot + 1)
	callout.horizontal_alignment = combo.horizontal_alignment
	if compact:  # shares the combo's line, at the panel's inner end
		callout.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if right_side else HORIZONTAL_ALIGNMENT_RIGHT
	callout.modulate.a = 0.0
	root.add_child(callout)
	p["callout"] = callout
	p["callout_tween"] = null

	var pause_tag := _label(t.pause_tag_font_size, t.pause_tag_color)
	pause_tag.name = "PauseTag%d" % (f.slot + 1)
	pause_tag.horizontal_alignment = name_label.horizontal_alignment
	if compact:  # after the ki count, at the panel's inner end
		pause_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if right_side else HORIZONTAL_ALIGNMENT_RIGHT
	pause_tag.visible = false
	root.add_child(pause_tag)
	p["pause_tag"] = pause_tag

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
	var ki_w := bar_w * t.ki_width_ratio

	timer_label.position = Vector2(w * 0.5 - t.center_gap * 0.5, t.top_margin)
	timer_label.size = Vector2(t.center_gap, t.timer_font_size + 16.0)
	announcer.size = Vector2(w, t.announce_font_size * 1.6)
	announcer.position = Vector2(0, h * 0.36 - announcer.size.y * 0.5)
	announcer.pivot_offset = announcer.size * 0.5
	waiting_label.size = Vector2(w, t.waiting_font_size + 16.0)
	waiting_label.position = Vector2(0.0, h * t.waiting_y_ratio)
	notice_label.size = Vector2(w, t.notice_font_size + 12.0)
	notice_label.position = waiting_label.position + Vector2(0.0, waiting_label.size.y)
	pause_list_label.size = Vector2(w, t.pause_tag_font_size + 10.0)
	pause_list_label.position = notice_label.position + Vector2(0.0, notice_label.size.y)
	if enemies_label != null:
		enemies_label.size = Vector2(w * 0.5, t.enemies_left_font_size + 12.0)
		enemies_label.position = Vector2(w * 0.25, t.top_margin + t.timer_font_size + 16.0)
		if wave_label != null:
			wave_label.size = enemies_label.size
			wave_label.position = enemies_label.position + Vector2(0.0, enemies_label.size.y)

	var side_rows: Array[int] = [0, 0]  # panel rows on the left / right
	for p: Dictionary in panels.values():
		var side := 1 if p["right"] else 0
		side_rows[side] = maxi(side_rows[side], int(p["row"]) + 1)
	for slot: int in panels:
		var p: Dictionary = panels[slot]
		var right: bool = p["right"]
		var row: int = p["row"]
		var compact: bool = p["compact"]
		var bar_h := t.stack_health_bar_height if compact else t.health_bar_height
		var ki_h := t.stack_ki_bar_height if compact else t.ki_bar_height
		var row_y := t.top_margin + row * t.stack_row_height
		var name_h := (t.stack_name_font_size if compact else t.name_font_size) + 8.0
		var bar_y := row_y + name_h
		var ki_y := bar_y + bar_h + 8.0
		var x0 := w * 0.5 + t.center_gap * 0.5 if right else t.side_margin
		var hb: HudHealthBar = p["health"]
		hb.position = Vector2(x0, bar_y)
		hb.size = Vector2(bar_w, bar_h)
		var nl: Label = p["name"]
		nl.position = Vector2(x0, row_y - 4.0)
		nl.size = Vector2(bar_w, name_h)
		var pips: HBoxContainer = p["pips"]
		pips.size = Vector2(bar_w * 0.4, t.pip_size)
		pips.position = Vector2(x0 if right else x0 + bar_w - pips.size.x, row_y + name_h * 0.5 - t.pip_size * 0.5)
		if right:
			pips.position.x += t.bar_skew + 4.0
		else:
			pips.position.x -= t.bar_skew + 4.0
		var kg: HudKiGauge = p["ki"]
		kg.size = Vector2(ki_w, ki_h)
		kg.position = Vector2(x0 + bar_w - ki_w if right else x0, ki_y)
		var kc: Label = p["ki_count"]
		kc.size = Vector2(40, ki_h + 20)
		var kc_x := kg.position.x - 46.0 if right else kg.position.x + ki_w + 6.0
		kc.position = Vector2(kc_x, ki_y - 12.0)
		var combo: Label = p["combo"]
		var callout: Label = p["callout"]
		var pause_tag: Label = p["pause_tag"]
		if compact:
			# One line per panel under its side's last row: combo at the
			# outer end, callout at the inner end.
			var line_h := t.stack_combo_font_size + 12.0
			var line_y := t.top_margin + side_rows[1 if right else 0] * t.stack_row_height + row * line_h
			combo.size = Vector2(bar_w, line_h)
			combo.position = Vector2(x0, line_y)
			callout.size = combo.size
			callout.position = combo.position
			callout.pivot_offset = Vector2(0.0 if right else callout.size.x, callout.size.y * 0.5)
			# Pause tag: between the ki count and the bar's inner end.
			var tag_w := bar_w - ki_w - 46.0
			pause_tag.size = Vector2(tag_w, t.pause_tag_font_size + 8.0)
			pause_tag.position = Vector2(x0 if right else x0 + bar_w - tag_w, ki_y - t.pause_tag_font_size * 0.5)
		else:
			combo.size = Vector2(bar_w, t.combo_font_size + 20.0)
			combo.position = Vector2(x0, ki_y + ki_h + 24.0)
			callout.size = Vector2(bar_w, t.callout_font_size + 16.0)
			callout.position = Vector2(x0, combo.position.y + combo.size.y)
			callout.pivot_offset = Vector2(callout.size.x if right else 0.0, callout.size.y * 0.5)
			pause_tag.size = Vector2(bar_w, t.pause_tag_font_size + 8.0)
			pause_tag.position = Vector2(x0, ki_y + ki_h + 2.0)
		combo.pivot_offset = Vector2(combo.size.x if right else 0.0, combo.size.y * 0.5)


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
	# A rollback's load_state re-sends the current count: don't pop it again.
	if hits >= t.combo_min_hits and int(p.get("combo_hits", 0)) == hits:
		return
	p["combo_hits"] = hits
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


# --- director signals / state -------------------------------------------------

func _process(_delta: float) -> void:
	_sync_state()
	_refresh_names()


## On-screen name of a slot: MatchConfig.player_tag, or "CPU (<name>)" once
## a CPU took over that human slot (director state, so right after a rollback).
static func slot_tag(d: MatchDirector, slot: int) -> String:
	if d == null or d.config == null:
		return "P%d" % (slot + 1)
	var tag := d.config.player_tag(slot)
	if d.controller_for_slot(slot) == MatchDirector.Controller.CPU and d.config_index(slot) >= 0 \
			and d.config.players[d.config_index(slot)].input_kind != PlayerSlotConfig.InputKind.CPU:
		return Tuning.hud.text_cpu_takeover % tag
	return tag


static func _name_text(tag: String, char_name: String, right_side: bool) -> String:
	return "%s  %s" % [tag, char_name] if not right_side else "%s  %s" % [char_name, tag]


## Panel names follow takeovers / reclaims.
func _refresh_names() -> void:
	for slot: int in panels:
		var p: Dictionary = panels[slot]
		var tag := slot_tag(director, slot)
		if tag != p.get("tag", ""):
			p["tag"] = tag
			(p["name"] as Label).text = _name_text(tag, p.get("char_name", ""), p["right"])


## Timer and enemies-left follow sim state (right after any rollback).
func _sync_state() -> void:
	if director == null or director.config == null:
		return
	var cfg := director.config
	var s := -1 if cfg.is_infinite_time() else ceili(maxi(director.round_frames_left, 0) / float(Tuning.match_rules.tick_rate))
	if s != _shown_seconds and director.phase != MatchDirector.Phase.NONE:
		_shown_seconds = s
		_on_timer_changed(s)
	if enemies_label != null and director.coop != null:
		var left := director.coop.enemies_left()
		if left != _shown_enemies:
			_shown_enemies = left
			_on_enemies_left_changed(left)


func _on_director_event(kind: StringName, data: Dictionary) -> void:
	_sync_state()
	if kind == &"phase_changed":
		_on_phase_changed(data["phase"])


func _on_confirmed_event(_tick: int, kind: StringName, data: Dictionary) -> void:
	match kind:
		&"round_started":
			_on_round_started(int(data["round_number"]))
		&"round_ended":
			_on_round_ended(int(data["winner_slot"]), data["reason"])
		&"match_ended":
			_on_match_ended(int(data["winner_slot"]))
		&"run_ended":
			if enemies_label != null:
				_on_run_ended(bool(data["cleared"]))
		&"wave_started":
			if wave_label != null:
				_on_wave_started(int(data["wave"]), int(data["total"]))
		&"wave_cleared":
			if wave_label != null and not data["last"]:  # the last one: run_ended announces
				announce(Tuning.hud.text_wave_clear, Tuning.hud.announce_color, Tuning.hud.announce_hold)


func _on_timer_changed(seconds_left: int) -> void:
	var t := Tuning.hud
	timer_label.visible = seconds_left >= 0 or not _coop()
	if seconds_left < 0:
		timer_label.text = t.text_infinite
		timer_label.label_settings.font_color = t.text_color
	else:
		timer_label.text = str(seconds_left)
		timer_label.label_settings.font_color = t.ko_color if seconds_left <= 10 else t.text_color


func _on_round_started(round_number: int) -> void:
	var t := Tuning.hud
	_refresh_pips()
	if _coop():
		return  # one run: just FIGHT!
	var is_final := false
	if director.config != null and director.config.rounds_to_win > 1:
		is_final = true
		for team in _teams():  # wins is indexed by team id (ids may have gaps)
			if team >= director.wins.size() or director.wins[team] < director.config.rounds_to_win - 1:
				is_final = false
	announce(t.text_final_round if is_final else t.text_round % round_number, t.announce_color, t.announce_hold)


func _on_phase_changed(phase: MatchDirector.Phase) -> void:
	if phase == MatchDirector.Phase.FIGHT:
		announce(Tuning.hud.text_fight, Tuning.hud.announce_color, Tuning.hud.announce_hold * 0.7)


func _on_round_ended(winner_slot: int, reason: StringName) -> void:
	if _coop():
		return  # run_ended announces the result
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
		announce(winner_text(winner_slot, false), _slot_color(winner_slot), Tuning.hud.announce_hold)


func _on_match_ended(winner_slot: int) -> void:
	if _coop():
		return
	announce(winner_text(winner_slot, true), _slot_color(winner_slot), -1.0)


## Round / match winner text for the team led by `winner_slot`: "P1 WINS"
## (online: the name), a team of 2+ by all its tags ("P1 & P3 WIN").
func winner_text(winner_slot: int, is_match: bool) -> String:
	var t := Tuning.hud
	var team := team_slots(director, winner_slot)
	if team.size() > 1:
		var tags: PackedStringArray = []
		for s in team:
			tags.append(director.config.player_tag(s))
		return (t.text_team_match_winner if is_match else t.text_team_round_winner) % t.text_team_join.join(tags)
	if _online():
		return (t.text_match_winner_name if is_match else t.text_round_winner_name) % director.config.player_tag(winner_slot)
	return (t.text_match_winner if is_match else t.text_round_winner) % (winner_slot + 1)


## Slots on the team of the fighter in `slot`, ascending (just `slot` when
## no fighter has it).
static func team_slots(d: MatchDirector, slot: int) -> Array[int]:
	var out: Array[int] = []
	var f := d.fighter_for_slot(slot) if d != null else null
	if f == null:
		out.append(slot)
		return out
	for other in d.fighters:
		if other.team == f.team:
			out.append(other.slot)
	out.sort()
	return out


## Team ids of the fighters, ascending.
func _teams() -> Array[int]:
	var out: Array[int] = []
	for f in director.fighters:
		if not f.team in out:
			out.append(f.team)
	out.sort()
	return out


func _online() -> bool:
	return director != null and director.config != null and director.config.is_online()


# --- online ----------------------------------------------------------------------

## "Waiting for <name>…" while `peer_name` is not empty (the match scene
## passes RollbackDriver.waiting_for() every frame).
func set_waiting(peer_name: String) -> void:
	waiting_label.visible = not peer_name.is_empty()
	if waiting_label.visible:
		waiting_label.text = Tuning.hud.text_waiting_for % peer_name


## Peers (other than this one) with the pause overlay open.
func set_paused_peers(peers: Array[int]) -> void:
	_paused_peers = peers.duplicate()
	_refresh_pause_tags()


func _refresh_pause_tags() -> void:
	if director == null or director.config == null:
		return
	var t := Tuning.hud
	var shown := {}  # peer -> true (has a panel tag)
	for slot: int in panels:
		var tag: Label = panels[slot]["pause_tag"]
		var peer := _owner_of(slot)
		tag.visible = peer != 0 and peer in _paused_peers
		if tag.visible:
			tag.text = t.text_pause_tag % director.config.player_tag(slot)
			shown[peer] = true
	var rest: PackedStringArray = []
	for p in director.config.players:
		if p.input_kind != PlayerSlotConfig.InputKind.CPU and p.owner_peer in _paused_peers \
				and not shown.has(p.owner_peer):
			shown[p.owner_peer] = true
			rest.append(t.text_pause_tag % director.config.player_tag(p.slot))
	pause_list_label.visible = not rest.is_empty()
	pause_list_label.text = "   ".join(rest)


func _owner_of(slot: int) -> int:
	for p in director.config.players:
		if p.slot == slot and p.input_kind != PlayerSlotConfig.InputKind.CPU:
			return p.owner_peer
	return 0


## Brief center notice under the waiting banner ("<name> disconnected").
func notice(text: String) -> void:
	var t := Tuning.hud
	if _notice_tween != null and _notice_tween.is_valid():
		_notice_tween.kill()
	notice_label.text = text
	notice_label.modulate.a = 1.0
	_notice_tween = create_tween()
	_notice_tween.tween_interval(t.notice_hold)
	_notice_tween.tween_property(notice_label, "modulate:a", 0.0, t.announce_out)


func _on_enemies_left_changed(left: int) -> void:
	if enemies_label != null:
		enemies_label.text = Tuning.hud.text_enemies_left % left


func _on_wave_started(wave: int, total: int) -> void:
	var t := Tuning.hud
	wave_label.text = t.text_wave_counter_endless % (wave + 1) if total < 0 else t.text_wave_counter % [wave + 1, total]
	var final := total > 1 and wave + 1 == total
	announce(t.text_final_wave if final else t.text_wave % (wave + 1), t.announce_color, t.announce_hold)


func _on_run_ended(cleared: bool) -> void:
	var t := Tuning.hud
	if cleared:
		announce(t.text_run_cleared, t.announce_color, -1.0)
	else:
		announce(t.text_run_failed, t.ko_color, -1.0)


func _slot_color(slot: int) -> Color:
	return Tuning.hud.slot_color(slot)


func _refresh_pips() -> void:
	for slot: int in panels:
		var pips: HBoxContainer = panels[slot]["pips"]
		var won := director.wins_for_slot(slot)
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
