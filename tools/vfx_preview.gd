extends Node
## Screenshots the match effects as a player sees them: a scripted 1v1 on a
## real MatchScene (ki charge aura, ki blasts, a beam, the opponent charging),
## then a gallery of hit / guard / vanish / KO effects fired at the opponent.
## `cam=side` films from the side (frozen camera) instead of P1's view.
## Needs a real window (no --headless):
##   godot res://tools/vfx_preview.tscn --resolution 1280x720 --fixed-fps 60 -- out=<dir>
##   [arena=beach_bar only=aura,blast distance=6]
## Add `--rendering-method gl_compatibility` for the web renderer.

const B := InputFrame.Btn

var _out := "user://"
var _only: PackedStringArray = []
var _distance := 6.0
var _side := false
var _scene: MatchScene
var _p: Array[ScriptedInput] = []


func _ready() -> void:
	var arena := ArenaCatalog.BEACH_BAR
	for pair in ToolArgs.pairs():
		var kv := pair.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"out": _out = kv[1]
			"arena": arena = StringName(kv[1])
			"only": _only = kv[1].split(",")
			"distance": _distance = kv[1].to_float()
			"cam": _side = kv[1] == "side"
	var cfg := MatchScene.build_default_config()
	cfg.arena_id = arena
	cfg.round_time_seconds = 0
	cfg.players[1].input_kind = PlayerSlotConfig.InputKind.CPU  # one view: P1's
	Game.current_config = cfg
	_scene = MatchScene.new()
	add_child(_scene)
	_run()


func _run() -> void:
	var d := _scene.director
	while d.phase != MatchDirector.Phase.FIGHT:
		await get_tree().physics_frame
	for i in 2:
		var s := ScriptedInput.new()
		_p.append(s)
		d.sources[i] = s
	await _reset()
	if _side:
		var cam: Camera3D = _scene.views.cameras.values()[0]
		cam.process_mode = Node.PROCESS_MODE_DISABLED
		cam.global_position = Vector3(_distance * 1.6, 2.1, 0.6)
		cam.look_at(Vector3(0.0, 1.1, 0.0))
	if _wants("aura"):
		_p[0].press(_rel(0), B.CHARGE, 100)
		await _shots("aura", [20, 45, 70, 95])
		await _frames(40)
	if _wants("blast"):
		await _reset()
		_p[0].press(_rel(0), B.BLAST, 2)
		await _shots("blast", [10, 14, 18])
		await _frames(40)
	if _wants("beam"):
		await _reset()
		_p[0].press(_rel(0), B.SPECIAL, 2)
		await _shots("beam", [30, 50, 70, 100])
		await _frames(120)
	if _wants("charge2"):
		await _reset()
		_p[1].press(_rel(1, 0), B.CHARGE, 80)
		await _shots("charge_p2", [50])
		await _frames(40)
	if _wants("fx"):
		await _reset()
		var vfx := _scene.vfx
		var victim := d.fighters[1]
		var hub := _scene.hub
		var chest := victim.global_position + Vector3.UP * Tuning.vfx.fallback_hit_height
		var cases := {
			"hit_light": {"blocked": false, "heavy": false},
			"hit_heavy": {"blocked": false, "heavy": true},
			"hit_blocked": {"blocked": true, "heavy": false},
		}
		for name: String in cases:
			var data: Dictionary = cases[name].duplicate()
			data["position"] = chest
			data["slot"] = victim.slot
			vfx._on_fighter_event(victim, &"hit", data)
			await _shots(name, [1, 3, 6, 10], false)
			await _frames(30)
		for kind: StringName in [&"guard_break", &"vanish", &"ko", &"ground_bounce", &"ultimate_start"]:
			var data := {"slot": victim.slot, "position": victim.global_position,
					"to": victim.global_position}
			vfx._on_fighter_event(victim, kind, data)
			await _shots(String(kind), [2, 6, 12], false)
			await _frames(40)
		hub = hub  # silence unused
	get_tree().quit()


func _wants(what: String) -> bool:
	return _only.is_empty() or what in _only


## Index of the next tick in `slot`'s script.
func _rel(slot: int, offset: int = 0) -> int:
	return _scene.director.tick + 1 - _p[slot].start_tick + offset


## Both fighters back at their marks, facing each other, full ki.
func _reset() -> void:
	var d := _scene.director
	for i in 2:
		var pos := Vector3(0, 0, _distance * 0.5 if i == 0 else -_distance * 0.5)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		d.fighters[i].ki = d.fighters[i].ki_max()
		d.fighters[i].health = d.fighters[i].tuning.max_health
		_p[i].frames.clear()
		_p[i].start_tick = d.tick + 1
	await _frames(20)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Screenshots `n` frames after now for each n in `at` (ascending).
func _shots(name: String, at: Array, _sim := true) -> void:
	var done := 0
	for n: int in at:
		await _frames(n - done)
		done = n
		await RenderingServer.frame_post_draw
		var path := "%s/%s_%02d.png" % [_out, name, n]
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("VFX_PREVIEW ", path, " ", error_string(err))
