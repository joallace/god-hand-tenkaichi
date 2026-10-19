extends Node
## Headless test for Targeting (target selection) and the TARGET input:
##   godot --headless res://tests/targeting_test.tscn
## Leaves user://controls.cfg exactly as it found it.

const FWD := Vector3(0, 0, -1)  # Godot forward; +X = the fighter's right

var _fails := 0


func _ready() -> void:
	_test_score()
	_test_pick_auto()
	_test_cycle()
	_test_cycle_dir()
	_test_input_frame()
	_test_bindings()
	print("TARGETING %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func cand(slot: int, pos: Vector3, attacking := false, targetable := true) -> Dictionary:
	return {"slot": slot, "pos": pos, "attacking_me": attacking, "targetable": targetable}


func _test_score() -> void:
	var o := Vector3.ZERO
	var ahead := Targeting.score(o, FWD, Vector3(0, 0, -4), false)
	var side := Targeting.score(o, FWD, Vector3(4, 0, 0), false)
	var behind := Targeting.score(o, FWD, Vector3(0, 0, 4), false)
	var far := Targeting.score(o, FWD, Vector3(0, 0, -10), false)
	check(ahead > side and side > behind, "score prefers ahead > side > behind")
	check(ahead > far, "score prefers closer")
	check(Targeting.score(o, FWD, Vector3(4, 0, 0), true) > side, "attacking bonus raises score")
	check(is_equal_approx(Targeting.score(o, FWD, Vector3(0, 5, -4), false), ahead), "height ignored")
	check(is_equal_approx(Targeting.score(o, FWD, Vector3(-4, 0, 0), false), side), "left/right symmetric")


func _test_pick_auto() -> void:
	var o := Vector3.ZERO
	var cs: Array[Dictionary] = [cand(2, Vector3(4, 0, 0)), cand(3, Vector3(0, 0, -4)), cand(4, Vector3(0, 0, 4))]
	check(Targeting.pick_auto(o, FWD, cs, -1) == 3, "auto picks the enemy ahead")
	var none: Array[Dictionary] = [cand(2, Vector3(0, 0, -4), false, false)]
	check(Targeting.pick_auto(o, FWD, none, -1) == -1, "auto returns -1 with nothing targetable")
	var empty: Array[Dictionary] = []
	check(Targeting.pick_auto(o, FWD, empty, 2) == -1, "auto returns -1 with no candidates")

	# Hysteresis: current slightly worse than the best -> kept; much worse -> dropped.
	var t := Tuning.targeting
	var close_call: Array[Dictionary] = [cand(2, Vector3(0, 0, -4)), cand(3, Vector3(0, 0, -4.5))]
	var gap := Targeting.score(o, FWD, Vector3(0, 0, -4), false) - Targeting.score(o, FWD, Vector3(0, 0, -4.5), false)
	check(gap > 0.0 and gap < t.hysteresis_margin, "fixture: close call is inside the margin")
	check(Targeting.pick_auto(o, FWD, close_call, 3) == 3, "hysteresis keeps a slightly worse current target")
	check(Targeting.pick_auto(o, FWD, close_call, -1) == 2, "without a current target the best wins")
	var big_gap: Array[Dictionary] = [cand(2, Vector3(0, 0, -4)), cand(3, Vector3(0, 0, 4))]
	check(Targeting.pick_auto(o, FWD, big_gap, 3) == 2, "a much better target replaces the current one")
	var cur_gone: Array[Dictionary] = [cand(2, Vector3(0, 0, -6)), cand(3, Vector3(0, 0, -4), false, false)]
	check(Targeting.pick_auto(o, FWD, cur_gone, 3) == 2, "untargetable current target is replaced")

	# Ties break by lower slot, regardless of order.
	var tie_a: Array[Dictionary] = [cand(5, Vector3(3, 0, -3)), cand(2, Vector3(-3, 0, -3))]
	var tie_b: Array[Dictionary] = [cand(2, Vector3(-3, 0, -3)), cand(5, Vector3(3, 0, -3))]
	check(Targeting.pick_auto(o, FWD, tie_a, -1) == 2 and Targeting.pick_auto(o, FWD, tie_b, -1) == 2,
		"score ties break by lower slot")

	var ok := true
	for i in 50:
		ok = ok and Targeting.pick_auto(o, FWD, cs, 2) == Targeting.pick_auto(o, FWD, cs, 2)
	check(ok, "pick_auto deterministic")


func _test_cycle() -> void:
	var o := Vector3.ZERO
	# Bearings clockwise from forward: 3 ahead (0), 2 right (90), 4 behind (180), 5 left (270).
	var cs: Array[Dictionary] = [
		cand(2, Vector3(4, 0, 0)), cand(3, Vector3(0, 0, -4)),
		cand(4, Vector3(0, 0, 4)), cand(5, Vector3(-4, 0, 0)),
	]
	check(is_equal_approx(Targeting.bearing(o, FWD, Vector3(4, 0, 0)), PI / 2), "bearing: right = 90 deg clockwise")
	var order: Array[int] = []
	var cur := 3
	for i in 4:
		cur = Targeting.cycle(o, FWD, cs, cur, 1)
		order.append(cur)
	check(order == [2, 4, 5, 3], "clockwise cycle ahead->right->behind->left->ahead (%s)" % [order])
	order.clear()
	cur = 3
	for i in 4:
		cur = Targeting.cycle(o, FWD, cs, cur, -1)
		order.append(cur)
	check(order == [5, 4, 2, 3], "counter-clockwise cycle order (%s)" % [order])

	check(Targeting.cycle(o, FWD, cs, -1, 1) == 3, "no current: clockwise starts straight ahead")
	check(Targeting.cycle(o, FWD, cs, -1, -1) == 3, "no current: counter-clockwise starts straight ahead")
	var skip: Array[Dictionary] = [cand(2, Vector3(4, 0, 0), false, false), cand(3, Vector3(0, 0, -4)), cand(4, Vector3(0, 0, 4))]
	check(Targeting.cycle(o, FWD, skip, 3, 1) == 4, "cycle skips untargetable")
	var solo: Array[Dictionary] = [cand(3, Vector3(0, 0, -4))]
	check(Targeting.cycle(o, FWD, solo, 3, 1) == 3, "cycle with one enemy keeps it")
	var nobody: Array[Dictionary] = [cand(3, Vector3(0, 0, -4), false, false)]
	check(Targeting.cycle(o, FWD, nobody, 3, 1) == -1, "cycle returns -1 with nothing targetable")
	# Same bearing: nearer first; the current target's twin comes after the others.
	var line: Array[Dictionary] = [cand(6, Vector3(0, 0, -8)), cand(7, Vector3(0, 0, -4)), cand(8, Vector3(4, 0, 0))]
	check(Targeting.cycle(o, FWD, line, -1, 1) == 7, "equal bearing: nearer first")
	check(Targeting.cycle(o, FWD, line, 7, 1) == 8, "equal-bearing twin comes after the others")
	check(Targeting.cycle(o, FWD, line, 8, 1) == 7, "wraps to the nearer of two at the same bearing")


func _test_cycle_dir() -> void:
	check(Targeting.cycle_dir(0) == 1, "neutral stick cycles clockwise")
	check(Targeting.cycle_dir(InputFrame.MOVE_SCALE) == 1, "stick right cycles clockwise")
	check(Targeting.cycle_dir(-InputFrame.MOVE_SCALE) == -1, "stick left cycles counter-clockwise")
	check(Targeting.cycle_dir(-10) == 1, "slight left tilt stays clockwise")


func _test_input_frame() -> void:
	check(InputFrame.Btn.TARGET == 1 << 12, "Btn.TARGET = 1 << 12")
	var ok := true
	for action in Bindings.BUTTON_ACTIONS:
		ok = ok and InputFrame.Btn.has(action)
	check(ok and "TARGET" in Bindings.BUTTON_ACTIONS, "every bindable button maps to an InputFrame.Btn")
	var f := InputFrame.new()
	f.held = InputFrame.Btn.TARGET | InputFrame.Btn.LIGHT
	var g := InputFrame.from_array(f.to_array())
	check(g.equals(f) and g.is_held(InputFrame.Btn.TARGET), "TARGET survives frame serialization")
	g.compute_edges(InputFrame.new())
	check(g.just_pressed(InputFrame.Btn.TARGET), "TARGET edge detected")


func _test_bindings() -> void:
	var lb := {"t": "btn", "i": JOY_BUTTON_LEFT_SHOULDER}
	check(Bindings.DEFAULT_PAD["TARGET"] == lb, "TARGET defaults to LB")
	for s in Bindings.SLOT_COUNT:
		check(not Bindings.DEFAULT_KEYBOARD[s].get("TARGET", {}).is_empty(), "keyboard layout %d binds TARGET" % s)
	check(Bindings.actions_for(Bindings.Kind.PAD).has("TARGET"), "TARGET listed for rebinding")

	# A controls.cfg saved before TARGET existed still loads; TARGET keeps its default.
	var existed := FileAccess.file_exists(Bindings.SAVE_PATH)
	var bytes := FileAccess.get_file_as_bytes(Bindings.SAVE_PATH) if existed else PackedByteArray()
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", Bindings.SAVE_VERSION)
	var old := Bindings.DEFAULT_PAD.duplicate(true)
	old.erase("TARGET")
	old["LIGHT"] = {"t": "btn", "i": JOY_BUTTON_BACK}
	for action in old:
		cfg.set_value("slot0_PAD", action, old[action])
	cfg.save(Bindings.SAVE_PATH)
	Bindings.reset_defaults(0)
	Bindings.load_from_disk()
	check(Bindings.get_binding(0, Bindings.Kind.PAD, "LIGHT")["i"] == JOY_BUTTON_BACK, "old config's bindings load")
	check(Bindings.get_binding(0, Bindings.Kind.PAD, "TARGET") == lb, "old config gets the TARGET default")

	if existed:
		var fa := FileAccess.open(Bindings.SAVE_PATH, FileAccess.WRITE)
		fa.store_buffer(bytes)
		fa.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Bindings.SAVE_PATH))
	for s in Bindings.SLOT_COUNT:
		Bindings.reset_defaults(s)
	Bindings.load_from_disk()
