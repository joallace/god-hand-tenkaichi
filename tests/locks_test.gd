extends Node
## Headless tests for lock interrupts (SPEC.md §4.5: a third party hitting a
## throw or vanish-battle participant frees both) and the ENTERING state of
## spawned enemies (§6.1). Run as a scene:
##   godot --headless res://tests/locks_test.tscn

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]
var _hit_serial := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_thrower_hit_frees_victim, _test_thrown_hit_frees_thrower,
		_test_partner_hit_is_not_a_break, _test_vanish_battle_interrupted,
		_test_entering, _test_save_load_mid_entry, _test_save_load_mid_recovery,
	]
	for t in tests:
		t.call()
	print("LOCKS TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in the FIGHT phase, one ScriptedInput fighter per `teams` entry.
func _new_match(teams: Array[int], friendly_fire: bool = false) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.friendly_fire = friendly_fire
	for i in teams.size():
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = teams[i]
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in teams.size():
		d.sources[i] = ScriptedInput.new()
	for f in d.fighters:
		f.event.connect(func(kind: StringName, data: Dictionary) -> void: _events.append([data["slot"], kind, data]))
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in teams.size():
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _place(d: MatchDirector, positions: Array[Vector3]) -> void:
	for i in positions.size():
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(Vector3.FORWARD), positions[i]))
	for f in d.fighters:
		f.target = d.pick_default_target(f)


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _count(kind: StringName, slot: int = -1) -> int:
	var n := 0
	for e: Array in _events:
		if e[1] == kind and (slot < 0 or e[0] == slot):
			n += 1
	return n


func _last(kind: StringName) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i][1] == kind:
			return _events[i][2]
	return {}


## Slot 0 grabs slot 1 (front throw); slot 2 stands aside. True once held.
func _grab(d: MatchDirector) -> bool:
	var f := d.fighters
	_place(d, [Vector3(0, 0, 0.7), Vector3(0, 0, -0.7), Vector3(2.5, 0, -0.7)])
	f[0].target = f[1]
	_src(d, 0).press(2, B.THROW)
	for i in 30:
		d.step()
		if f[1].current_state_name() == &"thrown":
			d.step()
			return f[0].current_state_name() == &"throw"
	return false


## A clean heavy from `by` landing on `victim` right now.
func _hit(by: Fighter, victim: Fighter) -> CombatEntity.Contact:
	_hit_serial += 1
	var hb := Hitbox.new()
	hb.source = by
	hb.attacker = by
	hb.move = by.def.move(by.def.heavy)
	hb.hit_id = (100000 + _hit_serial) * 256
	var dir := victim.global_position - by.global_position
	dir.y = 0.0
	hb.forward = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	hb.right = Vector3(-hb.forward.z, 0.0, hb.forward.x)
	hb.origin = by.global_position
	hb.a = victim.global_position + Vector3.UP
	hb.b = hb.a
	return victim.receive_hit(hb)


func _hash(d: MatchDirector) -> String:
	return var_to_str(d.save_state())


# --- tests --------------------------------------------------------------------

func _test_thrower_hit_frees_victim() -> void:
	var d := _new_match([0, 1, 1])
	var f := d.fighters
	# Slot 2 is the thrown victim's ally: it rescues by hitting the thrower.
	f[2].team = 1
	f[1].team = 1
	f[0].team = 0
	_check(_grab(d), "throw holds the victim")
	var hp := f[1].health
	var out := _hit(f[2], f[0])
	_check(out == CombatEntity.Contact.HIT, "ally of the victim hits the thrower")
	_check(_count(&"lock_broken", 0) == 1 and _last(&"lock_broken")["kind"] == &"throw"
		and int(_last(&"lock_broken")["by_slot"]) == 2, "lock_broken emitted by the hit thrower")
	_check(f[0].current_state_name() == &"hitstun" and f[1].current_state_name() == &"idle",
		"thrower takes the hit, victim back to neutral (%s, %s)" % [f[0].current_state_name(), f[1].current_state_name()])
	_check(f[1].is_invulnerable(), "freed victim gets brief invulnerability")
	_check(f[2].combo_hits == 1 and f[0].combo_hits == 0, "only the interrupter's own hit is credited")
	for i in 60:
		d.step()
	_check(f[1].health == hp, "throw damage never lands on the freed victim")


func _test_thrown_hit_frees_thrower() -> void:
	# Slot 2 is another enemy of the victim: it hits the thrown fighter.
	var d := _new_match([0, 1, 0])
	var f := d.fighters
	_check(_grab(d), "throw holds the victim")
	var out := _hit(f[2], f[1])
	_check(out == CombatEntity.Contact.HIT and _count(&"lock_broken", 1) == 1, "third party hits the thrown victim; lock broken")
	_check(f[1].current_state_name() == &"hitstun", "thrown victim takes the hit (%s)" % f[1].current_state_name())
	_check(f[0].current_state_name() == &"idle", "thrower released early (%s)" % f[0].current_state_name())
	d.step()
	_check(f[0].current_state_name() != &"throw" and f[1].current_state_name() != &"thrown", "nobody re-enters the lock")
	# Friendly fire on: the thrower's own teammate can hit the victim too.
	d = _new_match([0, 1, 0], true)
	f = d.fighters
	_check(_grab(d), "throw holds the victim (friendly fire on)")
	_hit(f[2], f[1])
	_check(f[0].current_state_name() == &"idle" and f[1].current_state_name() == &"hitstun", "teammate hit frees both too")


func _test_partner_hit_is_not_a_break() -> void:
	var d := _new_match([0, 1, 1])
	var f := d.fighters
	_check(_grab(d), "throw holds the victim")
	# A participant's own hit is never a third-party break (a held victim's
	# strike doesn't connect at all).
	var out := _hit(f[1], f[0])
	_check(out == CombatEntity.Contact.NONE and _count(&"lock_broken") == 0,
		"a participant's hit doesn't count as a third-party break")
	_check(f[0].current_state_name() == &"throw" and f[1].current_state_name() == &"thrown", "the throw holds")


func _test_vanish_battle_interrupted() -> void:
	var d := _new_match([0, 1, 1])
	var f := d.fighters
	_place(d, [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(3, 0, 1)])
	f[1].ki = f[1].ki_max()
	_check(f[1]._start_vanish_battle(f[0]), "vanish battle starts")
	_check(f[0].current_state_name() == &"vanish_wait" and f[1].current_state_name() == &"teleport", "responder waits, vanisher vanished")
	var out := _hit(f[2], f[0])
	_check(out == CombatEntity.Contact.HIT, "third party hits the waiting responder")
	_check(_count(&"lock_broken", 0) == 1 and _last(&"lock_broken")["kind"] == &"vanish_battle", "lock_broken (vanish battle)")
	_check(_count(&"vanish_battle_end") == 1 and int(_last(&"vanish_battle_end")["winner_slot"]) == -1, "battle ends with no winner")
	_check(not f[0].in_vanish_battle() and not f[1].in_vanish_battle(), "battle state cleared on both")
	var reappeared := false
	for i in 40:
		d.step()
		if f[1].current_state_name() != &"teleport":
			reappeared = true
			break
	_check(reappeared and _count(&"reappear", 1) >= 1, "vanisher reappears normally")
	_check(f[1].current_state_name() != &"vanish_wait", "partner not stuck waiting (%s)" % f[1].current_state_name())


func _test_entering() -> void:
	var d := _new_match([0, 1])
	var f := d.fighters
	_place(d, [Vector3(0, 0, 0.7), Vector3(0, 0, -0.7)])
	var n := 30
	f[1].begin_entry(n)
	_check(f[1].is_entering() and _count(&"entry", 1) == 1, "begin_entry enters ENTERING and emits entry")
	_check(not f[1].is_targetable() and f[1].get_hurtbox().is_empty() and f[1].is_invulnerable(),
		"entering: untargetable, intangible")
	_check(_hit(f[0], f[1]) == CombatEntity.Contact.NONE, "hits pass through an entering fighter")
	_src(d, 1).press(1, B.LIGHT)
	var start := f[1].global_position
	d.step()
	d.step()
	_check(f[1].is_entering() and f[1].current_state_name() == &"entering", "can't act while entering")
	# Bodies don't push while entering: overlap the two and step.
	f[1].global_position = f[0].global_position + Vector3(0.1, 0, 0)
	var before := f[0].global_position
	d.step()
	_check(f[0].global_position.distance_to(before) < 0.001, "no body push while entering")
	f[1].global_position = start
	for i in n:
		d.step()
	_check(f[1].current_state_name() == &"idle" and f[1].is_targetable(), "entry ends in IDLE, targetable")
	_check(_hit(f[0], f[1]) == CombatEntity.Contact.HIT, "hittable after entry")


func _test_save_load_mid_entry() -> void:
	var d := _new_match([0, 1])
	var f := d.fighters
	_place(d, [Vector3(0, 0, 2), Vector3(0, 0, -2)])
	f[1].begin_entry(30)
	for i in 10:
		d.step()
	var s := d.save_state()
	for i in 30:
		d.step()
	var a := _hash(d)
	d.load_state(s)
	_check(f[1].is_entering(), "load restores ENTERING")
	for i in 30:
		d.step()
	_check(_hash(d) == a, "mid-entry save/load re-sim identical")


func _test_save_load_mid_recovery() -> void:
	var d := _new_match([0, 1, 0])
	var f := d.fighters
	_check(_grab(d), "throw holds the victim")
	_hit(f[2], f[1])
	d.step()
	var s := d.save_state()
	for i in 30:
		d.step()
	var a := _hash(d)
	d.load_state(s)
	for i in 30:
		d.step()
	_check(_hash(d) == a, "mid-interrupt-recovery save/load re-sim identical")
