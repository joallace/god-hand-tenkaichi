extends Node
## Headless test for the match effects (VfxManager sprites, KiAura,
## KiBlastVisual, BeamVisual): every handled fighter event plays and
## finishes, effects only ever use the shared effect materials (no material
## or shader built per effect) and reuse pooled meshes, a quick repeat hit on
## the same victim plays a smaller burst, the ki aura flares up past full,
## settles and dies down after the charge, and the sprite shape / facing
## enums match the shader's constants.
##   godot --headless res://tests/vfx_test.tscn

const EVENTS: Array[StringName] = [
	&"hit", &"perfect_dodge", &"dodge", &"teleport", &"vanish", &"reappear", &"guard_break",
	&"push_off", &"counter_guard", &"throw", &"throw_break", &"ground_bounce", &"taunt_done",
	&"ko", &"ultimate_start", &"ki_blast", &"beam", &"entry", &"downed", &"revived", &"lock_broken",
]

var _ok := true


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)
	else:
		print("PASS ", what)


func _ready() -> void:
	_test_shader_enums()
	await _test_events()
	await _test_aura()
	await _test_projectile_visuals()
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


func _new_match() -> MatchDirector:
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in 2:
		d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	return d


## Sprite shapes / facings in FxMaterials match the shader's constants.
func _test_shader_enums() -> void:
	var code := FileAccess.get_file_as_string("res://presentation/vfx/shaders/fx_sprite.gdshaderinc")
	var re := RegEx.create_from_string("const int (SHAPE|FACE)_(\\w+) = (\\d+);")
	var found := {}
	for m in re.search_all(code):
		found["%s_%s" % [m.get_string(1), m.get_string(2)]] = m.get_string(3).to_int()
	for k: String in FxMaterials.Shape.keys():
		_check(found.get("SHAPE_" + k, -1) == FxMaterials.Shape[k], "shader SHAPE_%s matches FxMaterials.Shape" % k)
	for k: String in FxMaterials.Facing.keys():
		_check(found.get("FACE_" + k, -1) == FxMaterials.Facing[k], "shader FACE_%s matches FxMaterials.Facing" % k)
	_check(found.size() == FxMaterials.Shape.size() + FxMaterials.Facing.size(), "no shader shape/facing missing from the enums")
	for fx: FxMaterials.Fx in FxMaterials.Fx.values():
		var m := FxMaterials.shared(fx)
		_check(m.shader != null and m.shader.code.length() > 0, "shared effect shader %d loads" % fx)
		_check(FxMaterials.shared(fx) == m, "shared effect material %d is built once" % fx)


func _test_events() -> void:
	var d := _new_match()
	var hub := MatchEventHub.new()
	add_child(hub)
	hub.bind_director(d)
	hub.watch(d.fighters)
	var vfx := VfxManager.new()
	add_child(vfx)
	vfx.setup(hub)
	var victim := d.fighters[1]
	var chest := victim.global_position + Vector3.UP
	for kind in EVENTS:
		var data := {"slot": victim.slot, "position": chest, "attacker_slot": 0, "heavy": true}
		vfx._on_fighter_event(victim, kind, data)
		_check(kind == &"perfect_dodge" or kind == &"dodge" or vfx.active_count() > 0, "%s plays an effect" % kind)
		_check(_only_shared_materials(vfx), "%s only uses shared effect materials" % kind)
		await _settle(vfx)
	# A heavy hit is the busiest effect: replaying it must reuse the pool.
	var before := vfx.get_child_count()
	for i in 3:
		vfx._on_fighter_event(victim, &"hit", {"slot": victim.slot, "position": chest, "heavy": true})
		await _settle(vfx)
	_check(vfx.get_child_count() == before, "repeat hits reuse pooled sprites (no new nodes)")
	# Quick repeat hit on one victim (beam multi-hit): a smaller burst.
	vfx._on_fighter_event(victim, &"hit", {"slot": victim.slot, "position": chest, "heavy": true})
	var first := vfx.active_count()
	vfx._on_fighter_event(victim, &"hit", {"slot": victim.slot, "position": chest, "heavy": true})
	var second := vfx.active_count() - first
	_check(second > 0 and second < first, "a repeat hit within hit_repeat_window plays a smaller burst (%d < %d)" % [second, first])
	await _settle(vfx)
	vfx.queue_free()
	hub.queue_free()
	d.queue_free()
	await get_tree().process_frame


func _settle(vfx: VfxManager) -> void:
	for i in 60:  # up to 3 s of real time (headless frames can be very short)
		if vfx.active_count() == 0:
			return
		await get_tree().create_timer(0.05).timeout
	_check(vfx.active_count() == 0, "effects finish")


func _only_shared_materials(root: Node) -> bool:
	var shared: Array[Material] = []
	for fx: FxMaterials.Fx in FxMaterials.Fx.values():
		shared.append(FxMaterials.shared(fx))
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi.get_parent().name == "MaterialWarmUp" or gi.get_parent().name == "Afterimage" \
				or gi.get_parent() is Skeleton3D:
			continue
		if not gi.material_override in shared:
			return false
	return true


func _test_aura() -> void:
	var v := Tuning.vfx
	var aura := KiAura.new()
	add_child(aura)
	aura.setup(Color.ORANGE, Vector3.ONE)
	_check(_only_shared_materials(aura), "aura uses only shared effect materials")
	var dt := 1.0 / 60.0
	aura.update(dt, false, false, true)
	_check(not aura.visible, "aura hidden before charging")
	var peak := 0.0
	var t := 0.0
	while t < v.aura_ramp_in * 4.0:
		aura.update(dt, true, false, true)
		peak = maxf(peak, aura.power())
		t += dt
	_check(aura.visible, "aura shows while charging")
	_check(peak > 1.0, "aura flares up past full power when the charge starts (%.2f)" % peak)
	_check(is_equal_approx(aura.power(), 1.0), "aura settles at full power (%.2f)" % aura.power())
	aura.update(dt, true, false, false)
	_check(not aura.visible, "aura hidden while the body is (vanished)")
	aura.update(dt, false, false, true)
	_check(aura.visible and aura.power() < 1.0, "aura dies down instead of popping out")
	t = 0.0
	while t < v.aura_ramp_out + dt:
		aura.update(dt, false, false, true)
		t += dt
	_check(not aura.visible and aura.power() == 0.0, "aura gone after aura_ramp_out")
	aura.queue_free()
	await get_tree().process_frame


## A ki blast and a beam build their looks from shared materials only.
func _test_projectile_visuals() -> void:
	var d := _new_match()
	var f := d.fighters[0]
	f.ki = f.ki_max()
	var blast_move := f.def.move(f.def.ki_blast).spawn_move
	var blast := KiBlast.new()
	d.spawn_entity(blast)
	blast.launch(f, blast_move, f.global_position + Vector3.UP, d.fighters[1].global_position + Vector3.UP)
	await get_tree().process_frame
	_check(blast.find_children("*", "KiBlastVisual", true, false).size() == 1, "ki blast has its visual")
	_check(_only_shared_materials(blast), "ki blast uses only shared effect materials")
	var beam_move := f.def.move(f.def.super2).spawn_move
	var beam := Beam.new()
	d.spawn_entity(beam)
	beam.fire(f, beam_move, 0)
	await get_tree().process_frame
	_check(_only_shared_materials(beam), "beam uses only shared effect materials")
	d.queue_free()
	await get_tree().process_frame
