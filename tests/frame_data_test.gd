extends Node
## tools/frame_data.gd against the real sim: the advantage the sheet prints
## must be the gap between the attacker and the victim getting control back.
## Run as a scene:  godot --headless res://tests/frame_data_test.tscn

const B := InputFrame.Btn
const FrameData := preload("res://tools/frame_data.gd")
## States a victim is stuck in after a hit or a guarded hit.
const STUCK: Array[StringName] = [&"hitstun", &"guard_stun", &"guard_break"]

var _failures := 0


func _ready() -> void:
	_test_case(&"brawler_jab1", B.LIGHT, &"hit")
	_test_case(&"brawler_jab1", B.LIGHT, &"guard")        # plain guard
	_test_case(&"brawler_hook", B.LIGHT, &"hit", 2)       # third of the string
	_test_case(&"brawler_kick_mid", B.HEAVY, &"hit")      # stagger
	_test_case(&"brawler_kick_mid", B.HEAVY, &"high")     # ki guard
	_test_case(&"brawler_kick_mid", B.HEAVY, &"guard")    # mid guard: push-off
	_test_case(&"brawler_charge_kick", B.HEAVY, &"guard", 0, 120)  # full charge: ki guard (BT3)
	_test_case(&"brawler_charge_kick", B.HEAVY, &"guard", 0, 120, true)  # charge_breaks_guard: crash
	_test_sheet()
	print("FRAME DATA TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _new_match(distance: float) -> MatchDirector:
	for c in get_children():
		c.queue_free()
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
	for i in 2:
		var pos := Vector3(0, 0, distance * 0.5 if i == 0 else -distance * 0.5)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


## P1 taps `btn` (after `lead_in` LIGHT presses, to reach a later string
## step; their hits are skipped) into P2, who takes it (`how` = &"hit") or
## holds guard (&"guard" mid pose, &"high" stick forward). The gap between
## both getting control back must match the sheet.
## `hold` > 1 holds `btn` that many frames (a held HEAVY becomes the charge
## strike, released at full charge).
## `breaks` turns FighterTuning.charge_breaks_guard on for the case (off by
## default: BT3's full smashes never crash a guard).
func _test_case(move_id: StringName, btn: int, how: StringName, lead_in: int = 0, hold: int = 1,
		breaks: bool = false) -> void:
	var d := _new_match(1.4)
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var was_breaking := p1.tuning.charge_breaks_guard
	p1.tuning.charge_breaks_guard = breaks
	_run_case(d, move_id, btn, how, lead_in, hold, "%s %s%s" % [move_id, how, " (breaks)" if breaks else ""])
	p1.tuning.charge_breaks_guard = was_breaking


func _run_case(d: MatchDirector, move_id: StringName, btn: int, how: StringName, lead_in: int, hold: int,
		label: String) -> void:
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var guarded := how != &"hit"
	var p2_src := d.sources[1] as ScriptedInput
	if guarded:
		p2_src.press(0, B.GUARD, 300)
	if how == &"high":
		p2_src.stick(0, 300, Vector2(0, 1))
	var p1_src := d.sources[0] as ScriptedInput
	for k in lead_in:
		p1_src.press(4 + k * 14, B.LIGHT)
	p1_src.press(4 + lead_in * 14, btn, hold)
	var contact := -1
	var p1_free := -1
	var p2_free := -1
	for i in 300:
		d.step()
		var move := p1.current_move()
		if contact < 0 and p2.current_state_name() in STUCK and (move == null or move.id == move_id \
				or p1.current_state_name() == &"recoil"):
			contact = d.tick
			var used: StringName = move.id if move != null else p1.current_state_name()
			if not _check(used == move_id or (how == &"guard" and used == &"recoil"), "%s: P1 used %s" % [label, used]):
				return
		if contact >= 0 and p1_free < 0 and p1.current_state_name() == &"idle":
			p1_free = d.tick
		if contact >= 0 and p2_free < 0 and not p2.current_state_name() in STUCK:
			p2_free = d.tick
		if p1_free >= 0 and p2_free >= 0:
			break
	if not _check(contact >= 0 and p1_free >= 0 and p2_free >= 0, "%s: contact and recovery seen" % label):
		return
	var m := p1.def.move(move_id)
	var ratio := 1.0 if hold > 1 else 0.0
	var expected: Variant = FrameData.advantage_on_hit(m, p1.tuning, ratio)
	# Each case must cover the branch it is named for.
	var branch := String(FrameData.hit_reaction(m, p1.tuning, ratio)[1])
	if guarded:
		var res := m.guard_result(p2.guard_pose())
		var push_off := res == MoveData.GuardResult.PUSH_OFF or res == MoveData.GuardResult.PUSH_STOP
		if FrameData.crashes_guard(m, p1.tuning, ratio):
			branch = "crash"
			expected = FrameData.advantage_on_crash(m, p2.tuning)
		elif push_off:
			branch = "push_off"
			expected = FrameData.advantage_on_push_off(m, p2.tuning)
		else:
			branch = "ki_guard" if res == MoveData.GuardResult.KI_GUARD else "plain"
			expected = FrameData.advantage_on_guard(m)
	var want: String = {&"brawler_jab1 hit": "stun", &"brawler_jab1 guard": "plain",
		&"brawler_hook hit": "stun", &"brawler_kick_mid hit": "stagger",
		&"brawler_kick_mid high": "ki_guard", &"brawler_kick_mid guard": "push_off",
		&"brawler_charge_kick guard": "ki_guard",
		&"brawler_charge_kick guard (breaks)": "crash"}.get(StringName(label), "?")
	_check(branch == want, "%s: covers the %s branch (%s)" % [label, want, branch])
	var measured := p2_free - p1_free
	_check(expected != null and measured == int(expected),
		"%s: advantage %d in the sim, %s on the sheet" % [label, measured, expected])


func _test_sheet() -> void:
	for id in CharacterRegistry.ids():
		var def := CharacterRegistry.load_def(id)
		var rows := FrameData.rows(def, Tuning.fighter)
		_check(rows.size() >= def.moves.size(), "%s: a row per move (%d)" % [id, rows.size()])
		var ok := true
		for r in rows:
			ok = ok and r.size() == FrameData.COLUMNS.size()
		_check(ok, "%s: every row has every column" % id)
		# Victim-side numbers use the shared tuning, not the attacker's overrides.
		var first: Dictionary = rows[0]
		_check(is_equal_approx(float(first["dmg %"]),
				snappedf(float(first["damage"]) / Tuning.fighter.max_health * 100.0, 0.01)),
			"%s: dmg %% is out of the reference victim's health" % id)
		var md := FrameData.to_markdown(String(id), rows)
		_check(md.count("\n") == rows.size() + 4, "%s: markdown has a line per row" % id)
