extends Node
## Headless test for the co-op presentation layer: a MatchScene with a COOP
## config (2 local players on team 0) and the run's own enemies
## (CoopConfig.enemy_count of them, repositioned by the test once they spawn
## at the ring edge, checked after their entry ends), then: per-view CoopViewHud (partner panel, pips / edge arrows that
## follow spawns and removals, target pip following a target change, pips
## staying on their enemy when the view renders at a canvas->pixel scale != 1
## (large / DPI-scaled windows), ultimate banner on the other view only), global HUD (team-0 panels only, enemies
## left, infinite timer hidden), co-op events through VFX/SFX, KO fade, and
## the pause menu's Restart Run button.
##   godot --headless res://tests/coop_hud_test.tscn

const FRAMES := 240
const ENEMY_SLOTS: Array[int] = [2, 3, 4]

var _match: MatchScene
var _frame := 0
var _ok := true
var _enemies: Array[Fighter] = []


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = ENEMY_SLOTS.size()
	cfg.round_time_seconds = 0
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = 0
		p.device_kind = Bindings.Kind.KEYBOARD
		cfg.players.append(p)
	Game.current_config = cfg
	_match = (load(Game.SCENE_MATCH) as PackedScene).instantiate()
	add_child(_match)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)
	else:
		print("PASS ", what)


func _all_marked(ch: CoopViewHud) -> Array[int]:
	var out: Array[int] = []
	out.append_array(ch.pip_slots())
	out.append_array(ch.arrow_slots())
	out.sort()
	return out


func _physics_process(_delta: float) -> void:
	_frame += 1
	var d := _match.director
	match _frame:
		5:
			_check(_match.coop_huds.size() == 2, "a CoopViewHud per split-screen view")
			_check(_match.hud.panels.size() == 2, "global HUD panels for the two players only")
			_check(_match.hud.enemies_label != null, "enemies-left counter in co-op")
			_check(not _match.hud.timer_label.visible, "infinite run timer hidden")
			var p1 := d.fighters[0]
			var fwd := -p1.global_basis.z
			var spots: Array[Vector3] = [
				p1.global_position + fwd * 5.0,  # in front: on screen
				p1.global_position - fwd * 6.0,  # behind the camera: edge arrow
				p1.global_position + fwd * 7.0 + p1.global_basis.x * 3.0,
			]
			for i in ENEMY_SLOTS.size():
				var e := d.fighter_for_slot(ENEMY_SLOTS[i])
				e.set_control_enabled(false)
				e.global_position = spots[i]
				_enemies.append(e)
			_check((_match.hud.enemies_label.text) == Tuning.hud.text_enemies_left % 3, "enemies left = 3 after spawns")
		40:
			for slot: int in _match.coop_huds:
				var ch: CoopViewHud = _match.coop_huds[slot]
				_check(_all_marked(ch) == ENEMY_SLOTS, "view %d marks every enemy (pips %s, arrows %s)" % [slot, ch.pip_slots(), ch.arrow_slots()])
				_check(ch.partner_count() == 1, "view %d has one partner panel" % slot)
				_check(ch.find_children("Target*", "", false, false).is_empty(), "view %d has no top target panel" % slot)
			var ch0: CoopViewHud = _match.coop_huds[0]
			_check(_enemies[0].slot in ch0.pip_slots(), "enemy in front of P1 has a pip")
			_check(_enemies[1].slot in ch0.arrow_slots(), "enemy behind P1's camera gets an edge arrow")
			# Render P1's view at 2 pixels per canvas unit, as ViewLayout._fit
			# does for a window twice the base size.
			var panel: Control = _match.views.panels[0]
			var c: SubViewportContainer = _match.views._containers[panel]
			c.scale = Vector2.ONE * 0.5
			c.size = panel.size * 2.0
		41:
			var ch0: CoopViewHud = _match.coop_huds[0]
			var panel: Control = _match.views.panels[0]
			var c: SubViewportContainer = _match.views._containers[panel]
			var cam: FighterCamera = _match.views.cameras[0]
			var pos := SmoothedVisual.render_transform_of(_enemies[0]).origin + Vector3.UP * Tuning.hud.pip_world_height
			var on_screen := c.position + cam.unproject_position(pos) * c.scale
			var drawn := ch0.pip_point(_enemies[0].slot)
			_check(drawn.distance_to(on_screen) < 4.0, "pip stays over its enemy at pixel scale 2 (drawn %s, enemy %s)" % [drawn, on_screen])
			_match.views._fit(panel)
			# Lock P1 on the third enemy: the target pip follows.
			var p1 := d.fighters[0]
			p1.target = _enemies[2]
			p1.set(&"_target_locked", true)
		43:
			var ch0: CoopViewHud = _match.coop_huds[0]
			_check(ch0.target_pip_slot() == _enemies[2].slot or _enemies[2].slot in ch0.arrow_slots(),
					"target pip follows a target change (target pip %d)" % ch0.target_pip_slot())
			_check(ch0.target_pip_slot() != _enemies[0].slot, "previous target loses its highlight")
			# Ultimate by P2: banner on P1's view, not on P2's own.
			d.fighters[1].event.emit(&"ultimate_start", {"freeze_frames": 0})
			_check(ch0.banner_text() == Tuning.hud.text_ultimate_banner % "P2", "P1's view shows the P2 ULTIMATE banner")
			_check((_match.coop_huds[1] as CoopViewHud).banner_text() == "", "caster's own view has no banner")
			# Co-op events go through VFX / SFX without errors.
			var f0 := d.fighters[0]
			for kind: StringName in [&"downed", &"revive_start", &"revive_cancel", &"revived", &"out"]:
				f0.event.emit(kind, {"slot": 0, "reviver_slot": 1, "position": f0.global_position})
			f0.event.emit(&"lock_broken", {"slot": 0, "partner_slot": 2, "by_slot": 1, "kind": &"throw", "position": f0.global_position})
			# KO the first enemy (presentation only reads health): it fades.
			_enemies[0].health = 0.0
		50:
			# Remove the second enemy mid-match.
			d.remove_fighter(_enemies[1])
		100:
			_check(_match.hud.enemies_label.text == Tuning.hud.text_enemies_left % 1, "enemies left counts KO + removal (%s)" % _match.hud.enemies_label.text)
			for slot: int in _match.coop_huds:
				var ch: CoopViewHud = _match.coop_huds[slot]
				_check(_all_marked(ch) == [_enemies[2].slot], "view %d marks only the remaining enemy (%s)" % [slot, _all_marked(ch)])
		110:
			var vis := _enemies[0].find_children("*", "FighterVisual", true, false)
			_check(not vis.is_empty() and (vis[0] as FighterVisual).fade_amount() > 0.0, "KO'd enemy fades out")
			var live := _enemies[2].find_children("*", "FighterVisual", true, false)
			_check(not live.is_empty() and (live[0] as FighterVisual).fade_amount() == 0.0, "standing enemy stays solid")
			d.pause_requested.emit(1)
			_check(_match.pause_menu.find_children("RestartRun", "Button", true, false).size() == 1, "pause menu has Restart Run")
		120:
			_match.pause_menu.resume()
		FRAMES:
			_finish()


func _finish() -> void:
	print("COOP HUD TEST %s (frames=%d)" % ["PASS" if _ok else "FAIL", _frame])
	get_tree().quit(0 if _ok else 1)
