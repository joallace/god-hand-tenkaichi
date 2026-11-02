extends Node3D
## Screenshots a stage from fixed spots, without a match; `match=1` instead
## shoots a CPU vs CPU match on it, as a player sees it. Needs a real window
## (no --headless). Add `--rendering-method gl_compatibility` to see what the
## web build's renderer draws.
##   godot res://tools/arena_preview.tscn --resolution 1280x720 -- arena=beach_bar radius=18 out=/some/dir

const SETTLE_FRAMES := 12
const MATCH_SHOTS := 3
const MATCH_SHOT_SECONDS := 6.0


func _ready() -> void:
	var id := ArenaCatalog.BEACH_BAR
	var r := Tuning.match_rules.arena_radius
	var out := "user://"
	var in_match := false
	for pair in ToolArgs.pairs():
		var kv := pair.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"arena": id = StringName(kv[1])
			"radius": r = kv[1].to_float()
			"out": out = kv[1]
			"match": in_match = kv[1] == "1"
	if in_match:
		_shoot_match(id, out)
		return
	var arena := Arena.create(id)
	arena.radius = r
	add_child(arena)
	var cam := Camera3D.new()
	cam.fov = Tuning.camera.fov_single
	cam.far = Tuning.camera.far
	add_child(cam)
	cam.make_current()
	var limit := r + Tuning.camera.radius_margin
	var shots := {
		"p1_opening": [Vector3(0.0, 2.2, 6.0), Vector3(0.0, 1.2, -4.0)],
		"p2_opening": [Vector3(0.0, 2.2, -6.0), Vector3(0.0, 1.2, 4.0)],
		"edge_tables": [Vector3(6.0, 2.2, -r + 8.0), Vector3(-1.0, 1.0, -r - 8.0)],
		"edge_sea": [Vector3(-5.0, 2.2, r - 6.0), Vector3(5.0, 1.4, r + 10.0)],
		"along_beach": [Vector3(-limit * 0.7, 2.6, 4.0), Vector3(limit, 2.0, -6.0)],
		"overview": [Vector3(limit * 0.9, 34.0, limit * 1.5), Vector3(0.0, 0.0, -8.0)],
	}
	for shot: String in shots:
		cam.global_position = shots[shot][0]
		cam.look_at(shots[shot][1])
		for i in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/%s_%s.png" % [out, id, shot]
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("ARENA_PREVIEW ", path, " ", error_string(err))
	get_tree().quit()


func _shoot_match(id: StringName, out: String) -> void:
	var cfg := MatchScene.build_default_config()
	cfg.arena_id = id
	for p in cfg.players:
		p.input_kind = PlayerSlotConfig.InputKind.CPU
	Game.current_config = cfg
	var scene := MatchScene.new()
	add_child(scene)
	for i in MATCH_SHOTS:
		await get_tree().create_timer(MATCH_SHOT_SECONDS).timeout
		await RenderingServer.frame_post_draw
		var path := "%s/%s_match_%d.png" % [out, id, i]
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("ARENA_PREVIEW ", path, " ", error_string(err))
	get_tree().quit()
