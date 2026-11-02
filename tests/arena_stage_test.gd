extends Node
## Stages (ArenaCatalog / Arena.create): the factory, and the beach bar's
## layout against the play circle and the camera at every arena size: nothing
## stands inside the rope, nothing tall where the camera can go, the sea stays
## clear of the sand's props. Plus the build itself and a real match on it.
## Run as a scene:  godot --headless res://tests/arena_stage_test.tscn

## Footprints around a spot: chairs around a table, an umbrella's canopy.
const TABLE_REACH := 1.5
const UMBRELLA_REACH := BeachArena.UMBRELLA_RADIUS
const MATCH_FRAMES := 30

var _fails := 0


func _ready() -> void:
	_test_catalog()
	_test_layout(Tuning.match_rules.arena_radius)
	var biggest := Tuning.match_rules.arena_radius \
			+ Tuning.coop.arena_radius_per_extra_fighter * (Tuning.coop.field_cap - 2)
	_test_layout(biggest)
	await _test_build()
	await _test_match_scene()
	print("ARENA_STAGE %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func _test_catalog() -> void:
	var stone := Arena.create(ArenaCatalog.DEFAULT)
	var beach := Arena.create(ArenaCatalog.BEACH_BAR)
	var unknown := Arena.create(&"from_a_newer_build")
	check(stone.get_script() == Arena, "default id builds the stone ring")
	check(beach is BeachArena, "beach_bar id builds the beach")
	check(unknown.get_script() == Arena, "an unknown id falls back to the default")
	stone.free()
	beach.free()
	unknown.free()
	for id in ArenaCatalog.IDS:
		check(ArenaCatalog.NAMES.has(id), "%s has a display name" % id)


func _test_layout(r: float) -> void:
	var b := Tuning.arena_beach
	var cam := r + Tuning.camera.radius_margin
	var tables := BeachArena.table_spots(r)
	var umbrellas := BeachArena.umbrella_spots(r)
	check(tables.size() >= 8, "r=%.1f: %d tables" % [r, tables.size()])
	check(umbrellas.size() >= 8, "r=%.1f: %d umbrellas" % [r, umbrellas.size()])
	var inside := 0
	for t in tables:
		if t.length() - TABLE_REACH <= r:
			inside += 1
		if t.y >= 0.0:
			inside += 1
	check(inside == 0, "r=%.1f: tables on the bar's side, outside the rope" % r)
	var bar_clear := true
	for t in tables:
		if -t.y + TABLE_REACH > -BeachArena.bar_z(r):
			bar_clear = false
	check(bar_clear, "r=%.1f: tables between the rope and the bar" % r)
	var tall_clear := true
	var dry := true
	for u in umbrellas:
		if u.length() - UMBRELLA_REACH <= cam:
			tall_clear = false
		if u.y <= 0.0 or u.y + UMBRELLA_REACH >= BeachArena.shore_z(u.x, r) - b.swash_reach:
			dry = false
	check(tall_clear, "r=%.1f: umbrellas beyond the camera's limit (%.1f m)" % [r, cam])
	check(dry, "r=%.1f: umbrellas stay on dry sand" % r)
	check(-BeachArena.bar_z(r) - BeachArena.AWNING_DEPTH > cam, "r=%.1f: the bar and its awning are beyond the camera's limit" % r)
	check(BeachArena.shore_z(0.0, r) - b.swash_reach > cam, "r=%.1f: the water is beyond the camera's limit" % r)
	check(BeachArena.shore_z(200.0, r) < BeachArena.shore_z(0.0, r)
			and BeachArena.shore_z(-200.0, r) > BeachArena.shore_z(0.0, r), "r=%.1f: the bay curves" % r)


func _test_build() -> void:
	var arena := Arena.create(ArenaCatalog.BEACH_BAR)
	arena.radius = Tuning.match_rules.arena_radius
	add_child(arena)
	await get_tree().process_frame
	var props := arena.get_node("Props")
	for node_name: String in ["Tables", "Chairs", "Umbrellas", "Palms", "Towers", "Bar", "Rope"]:
		check(props.has_node(node_name), "stage has its %s" % node_name)
	check(arena.has_node("FloorBody"), "stage has the floor collider")
	check(arena.has_node("Sun") and arena.has_node("WorldEnvironment"), "stage has its light and sky")
	var chairs := props.get_node("Chairs") as MultiMeshInstance3D
	check(chairs.multimesh.instance_count > BeachArena.table_spots(arena.radius).size(), "tables have chairs")
	var texts: Array[String] = []
	for c in props.get_children():
		if c is Label3D:
			texts.append(c.text)
	check(Tuning.arena_beach.brand_a_name in texts and Tuning.arena_beach.brand_b_name in texts, "both brands are shown")
	check(texts.size() < 32, "wordmarks stay few enough to be cheap (%d)" % texts.size())
	arena.queue_free()


## A whole match scene on the stage: config -> Arena.create -> running.
func _test_match_scene() -> void:
	var cfg := MatchScene.build_default_config()
	cfg.arena_id = ArenaCatalog.BEACH_BAR
	for p in cfg.players:
		p.input_kind = PlayerSlotConfig.InputKind.CPU
	Game.current_config = cfg
	var scene := MatchScene.new()
	add_child(scene)
	for i in MATCH_FRAMES:
		await get_tree().process_frame
	check(scene.arena is BeachArena, "a match with the beach's id plays on the beach")
	check(is_equal_approx(scene.arena.radius, scene.director.arena_radius), "stage and sim agree on the radius")
	check(scene.director.fighters.size() == cfg.players.size(), "the match runs with its fighters")
	Game.current_config = null
	scene.free()
