extends Node
## Headless test for the match presentation layer: instantiates
## scenes/match/match.tscn with a default 2-local-player config, runs ~260
## physics frames, fires synthetic fighter events (hit, perfect dodge, teleport,
## guard break, ultimate, not_enough_ki) and a pause/resume, then checks the
## split-screen cameras + HUD exist.
##   godot --headless res://tests/match_scene_test.tscn

const FRAMES := 260

var _match: MatchScene
var _frame := 0
var _ok := true


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var cfg := MatchConfig.from_defaults()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.device_kind = Bindings.Kind.KEYBOARD
		cfg.players.append(p)
	Game.current_config = cfg
	_match = (load(Game.SCENE_MATCH) as PackedScene).instantiate()
	add_child(_match)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)


func _physics_process(_delta: float) -> void:
	_frame += 1
	var d := _match.director
	match _frame:
		100:
			var f0 := d.fighters[0]
			var f1 := d.fighters[1]
			f1.event.emit(&"hit", {"attacker_slot": 0, "damage": 50.0, "position": f1.global_position + Vector3.UP, "heavy": false, "blocked": false})
			f0.event.emit(&"hit", {"attacker_slot": 0, "damage": 50.0, "position": f1.global_position + Vector3.UP, "heavy": false, "blocked": false})
			f0.event.emit(&"hit", {"attacker_slot": 1, "damage": 90.0, "position": f0.global_position + Vector3.UP, "heavy": true, "blocked": false})
			f1.event.emit(&"hit", {"attacker_slot": 0, "damage": 5.0, "position": f1.global_position + Vector3.UP, "heavy": false, "blocked": true})
			f0.event.emit(&"perfect_dodge", {})
			f1.event.emit(&"teleport", {})
			f0.event.emit(&"vanish", {"exchange": 1})
			f1.event.emit(&"guard_break", {})
			f1.event.emit(&"hit", {"attacker_slot": 0, "damage": 5.0, "position": f1.global_position + Vector3.UP, "heavy": true, "blocked": true, "guard_result": MoveData.GuardResult.KI_GUARD})
			f1.event.emit(&"hit", {"attacker_slot": 0, "damage": 5.0, "position": f1.global_position + Vector3.UP, "heavy": true, "blocked": true, "guard_result": MoveData.GuardResult.PUSH_OFF})
			f1.event.emit(&"push_off", {"attacker_slot": 0, "position": f1.global_position, "stop": true})
			f0.event.emit(&"counter_guard", {"attacker_slot": 1, "position": f0.global_position})
			f0.event.emit(&"throw", {"target_slot": 1, "position": f0.global_position})
			f1.event.emit(&"throw_break", {"attacker_slot": 0, "position": f1.global_position})
			f1.event.emit(&"ground_bounce", {"position": f1.global_position})
			f0.event.emit(&"taunt", {})
			f0.event.emit(&"taunt_done", {"ki": 100.0})
			f0.event.emit(&"charge_release", {"ratio": 1.0, "dir": &"forward"})
			_check((_match.hud.panels[1]["callout"] as Label).text == Tuning.hud.text_throw_break, "throw break callout")
			_check((_match.hud.panels[0]["callout"] as Label).text == Tuning.hud.text_counter, "counter callout")
			f0.event.emit(&"ultimate_start", {})
			f0.event.emit(&"not_enough_ki", {})
			f1.event.emit(&"beam", {})
			f1.event.emit(&"super_start", {"kind": &"beam"})
			f0.state_changed.emit(&"charge")
			_check(Sfx.is_looping(f0), "ki charge loop starts")
			f0.state_changed.emit(&"idle")
			_check(not Sfx.is_looping(f0), "ki charge loop stops")
			f0.combo_changed.emit(5)
			f1.health_changed.emit(700.0, 1000.0)
			f0.ki_changed.emit(250.0, 500.0)
		110:
			d.pause_requested.emit(0)
			_check(d.paused and get_tree().paused and _match.pause_menu.visible, "pause opens")
		120:
			_match.pause_menu.resume()
			_check(not d.paused and not get_tree().paused, "resume")
		FRAMES:
			_finish()


func _finish() -> void:
	var cams := _match.find_children("*", "FighterCamera", true, false)
	_check(cams.size() == 2, "expected 2 FighterCameras, got %d" % cams.size())
	_check(_match.views.cameras.size() == 2, "views registered 2 cameras")
	for c in cams:
		var cam := c as FighterCamera
		_check(cam.get_viewport() is SubViewport, "camera inside SubViewport")
		_check(cam.get_viewport().world_3d == _match.get_viewport().find_world_3d(), "shared World3D")
		var f := cam.fighter
		var to_opp := (f.target.global_position - f.global_position)
		var to_cam := (cam.global_position - f.global_position)
		to_opp.y = 0
		to_cam.y = 0
		_check(to_opp.dot(to_cam) < 0.0, "camera behind its fighter (slot %d)" % f.slot)
	_check(_match.hud != null and _match.hud.panels.size() == 2, "HUD with 2 panels")
	_check(_match.sfx != null and _match.sfx.is_inside_tree(), "MatchSfx present")
	_check(_match.hud.timer_label.text != "", "timer text")
	_check(_match.director.phase == MatchDirector.Phase.FIGHT, "in FIGHT phase")
	print("MATCH SCENE TEST %s (frames=%d, cameras=%d, timer=%s)" % ["PASS" if _ok else "FAIL", _frame, cams.size(), _match.hud.timer_label.text])
	get_tree().quit(0 if _ok else 1)
