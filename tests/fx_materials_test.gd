extends Node
## Headless test for FxMaterials (no shader recompiles during combat):
## effect materials keep their template's feature flags (so they share its
## generated shader), the template outlives every effect (so that shader is
## never freed), warm_up() draws each kind then cleans up, and no runtime
## code toggles emission_enabled (a shader swap per hit flash).
##   godot --headless res://tests/fx_materials_test.tscn

## BaseMaterial3D properties that pick its generated shader (the ones we set).
const SHADER_KEY_PROPS: Array[StringName] = [
	&"shading_mode", &"transparency", &"blend_mode", &"cull_mode", &"no_depth_test",
	&"emission_enabled",
]
## Sources that build materials at runtime (fighters, projectiles, effects).
const SOURCE_DIRS: Array[String] = ["res://gameplay/", "res://presentation/"]

var _ok := true


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)


func _ready() -> void:
	_test_copies_share_shader()
	await _test_shader_outlives_effects()
	await _test_warm_up()
	_test_fighter_glow_keeps_shader()
	_test_no_emission_toggles()
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


func _test_copies_share_shader() -> void:
	for kind: FxMaterials.Kind in FxMaterials.Kind.values():
		var t := FxMaterials.template(kind)
		var a := FxMaterials.make(kind, Color.RED)
		var b := FxMaterials.make(kind, Color.BLUE)
		_check(_same_shader_key(a, t) and _same_shader_key(b, t),
				"copies of kind %d share the template's shader flags" % kind)
		_check(a.albedo_color == Color.RED and t.albedo_color == Color.WHITE,
				"make() tints the copy, not the template (kind %d)" % kind)
		_check(FxMaterials.template(kind) == t, "template %d is built once" % kind)


func _test_shader_outlives_effects() -> void:
	var vfx := VfxManager.new()
	add_child(vfx)
	var before := FxMaterials.template(FxMaterials.Kind.TRANSLUCENT_ON_TOP)
	vfx.hit_spark(Vector3.ZERO, Color.ORANGE, 1.0, 0.01, 3)
	vfx.shockwave(Vector3.ZERO, Color.ORANGE, 1.0, 0.01)
	for i in 30:  # every effect tweens out and frees itself
		await get_tree().process_frame
	_check(vfx.get_children().all(func(c: Node) -> bool: return c.name == "MaterialWarmUp"),
			"effects freed themselves")
	_check(FxMaterials.template(FxMaterials.Kind.TRANSLUCENT_ON_TOP) == before,
			"template (and its shader) survives all effects being freed (no recompile)")
	vfx.queue_free()
	await get_tree().process_frame


func _test_warm_up() -> void:
	var root := Node3D.new()
	add_child(root)
	FxMaterials.warm_up(root)
	var holder := root.get_node_or_null("MaterialWarmUp")
	_check(holder != null, "warm_up adds a holder")
	if holder != null:
		_check(holder.get_child_count() == FxMaterials.Kind.size(), "one warm-up mesh per kind")
		var all_drawn := true
		for c in holder.get_children():
			var mi := c as MeshInstance3D
			all_drawn = all_drawn and mi.visible and mi.custom_aabb.size.length() > 0.0
		_check(all_drawn, "warm-up meshes are visible and never culled")
	for i in Tuning.vfx.material_warmup_frames + 2:
		await get_tree().process_frame
	_check(root.get_node_or_null("MaterialWarmUp") == null, "warm-up holder freed after its frames")
	root.queue_free()


func _same_shader_key(a: BaseMaterial3D, b: BaseMaterial3D) -> bool:
	for p in SHADER_KEY_PROPS:
		if a.get(p) != b.get(p):
			return false
	return true


## The body material keeps emission on from build time (glow = energy only).
func _test_fighter_glow_keeps_shader() -> void:
	var visual := FighterVisual.new()
	add_child(visual)
	_check(visual._mat.emission_enabled, "fighter body material has emission on from the start")
	_check(is_zero_approx(visual._mat.emission_energy_multiplier), "fighter starts with no glow")
	visual.queue_free()


## A runtime `emission_enabled = <expr>` other than `true` swaps shaders.
func _test_no_emission_toggles() -> void:
	var re := RegEx.create_from_string("emission_enabled\\s*=\\s*+(?!true\\b)")
	for path in _scripts():
		var text := FileAccess.get_file_as_string(path)
		var lines := text.split("\n")
		for i in lines.size():
			if re.search(lines[i]) != null:
				_check(false, "%s:%d toggles emission_enabled (vary emission energy instead)" % [path, i + 1])


func _scripts() -> PackedStringArray:
	var out := PackedStringArray()
	var stack: Array[String] = SOURCE_DIRS.duplicate()
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for d in DirAccess.get_directories_at(dir):
			stack.append(dir + d + "/")
		for f in DirAccess.get_files_at(dir):
			if f.get_extension() == "gd":
				out.append(dir + f)
	return out
