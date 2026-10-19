extends Node
## Per-fighter hitstop, world freeze and victim-side combo scaling. Run as a
## scene:  godot --headless res://tests/hitstop_test.tscn
## Uses a 3-fighter match (slot 2 = bystander / second attacker) built by
## hand: until teams land, the director only pairs opponents for 2 fighters.

const B := InputFrame.Btn

var _failures := 0
var _events: Array = []  # [slot, kind, data]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_pair_freezes, _test_bystander_moves, _test_world_freeze,
		_test_frozen_source_no_contact, _test_victim_side_scaling, _test_save_load,
	]
	for t in tests:
		t.call()
	print("HITSTOP TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## FIGHT-phase match with `count` fighters. P1 (slot 0) at +z, P2 (slot 1) at
## -z, both `distance` apart; slot 2 (if any) placed at `third_pos` facing P2.
func _new_match(count: int = 2, distance: float = 1.4, third_pos := Vector3(3, 0, 0)) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	for i in count:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in count:
		d.sources[i] = ScriptedInput.new()
	if count > 2:
		d.fighters[2].opponent = d.fighters[1]
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in count:
		var pos := Vector3(0, 0, distance * 0.5 if i == 0 else -distance * 0.5)
		var look := -pos
		if i == 2:
			pos = third_pos
			look = d.fighters[1].global_position - pos
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(look.normalized()), pos))
		d.fighters[i].event.connect(func(kind: StringName, data: Dictionary) -> void:
			_events.append([i, kind, data]))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _event_count(kind: StringName, slot: int = -1) -> int:
	var n := 0
	for e: Array in _events:
		if e[1] == kind and (slot < 0 or e[0] == slot):
			n += 1
	return n


func _run_until(d: MatchDirector, cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		d.step()
		if cond.call():
			return true
	return false


func _hit_damages(slot: int) -> Array:
	var out: Array = []
	for e: Array in _events:
		if e[0] == slot and e[1] == &"hit":
			out.append(e[2]["damage"])
	return out


# --- tests ---------------------------------------------------------------------

## 1v1: a clean hit freezes attacker and victim for the move's hitstop.
func _test_pair_freezes() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	var stop := p1.hitstop_left()
	_check(stop > 0 and p2.hitstop_left() == stop, "hit freezes attacker and victim (%d / %d)" % [stop, p2.hitstop_left()])
	var f1 := p1.state_frame()
	var f2 := p2.state_frame()
	for i in stop:
		d.step()
	_check(p1.state_frame() == f1 and p2.state_frame() == f2, "frozen fighters don't advance during hitstop")
	d.step()
	_check(p1.state_frame() == f1 + 1 and p2.hitstop_left() == 0, "both resume after hitstop")


## A third fighter keeps simulating while another pair is in hitstop.
func _test_bystander_moves() -> void:
	var d := _new_match(3)
	var p1 := d.fighters[0]
	var by := d.fighters[2]
	_src(d, 0).press(0, B.LIGHT)
	_src(d, 2).stick(0, 120, Vector2(0, 1))
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	var stop := p1.hitstop_left()
	var pos := by.global_position
	var f := by.state_frame()
	for i in stop:
		d.step()
	_check(by.hitstop_left() == 0 and by.state_frame() > f and by.global_position.distance_to(pos) > 0.01,
		"bystander keeps moving during another pair's hitstop (moved %.2f m)" % by.global_position.distance_to(pos))


## request_world_freeze stops every fighter (and the round timer).
func _test_world_freeze() -> void:
	var d := _new_match(3)
	d.config.round_time_seconds = 99
	d.round_frames_left = 99 * Tuning.match_rules.tick_rate
	_src(d, 2).stick(0, 120, Vector2(0, 1))
	_src(d, 0).stick(0, 120, Vector2(0, 1))
	d.step()
	var frames: Array[int] = []
	for f in d.fighters:
		frames.append(f.state_frame())
	var pos := d.fighters[2].global_position
	var left := d.round_frames_left
	d.request_world_freeze(10)
	for i in 9:
		d.step()
	_check(d.round_frames_left == left, "world freeze pauses the round timer")
	d.step()  # last frozen tick (the timer resumes on it, as with the old global hitstop)
	var still := true
	for i in d.fighters.size():
		still = still and d.fighters[i].state_frame() == frames[i]
	_check(still and d.fighters[2].global_position == pos, "world freeze stops every fighter")
	d.step()
	_check(d.fighters[2].state_frame() == frames[2] + 1, "world resumes after the freeze")


## A source in hitstop makes no new contacts; a frozen victim can still be hit.
func _test_frozen_source_no_contact() -> void:
	var d := _new_match()
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return not p1.get_active_hitboxes().is_empty(), 30)
	# The hitbox is live but hasn't been resolved yet; freeze P1 first.
	p1.hitstop = 5
	var hp := p2.health
	d.step()
	_check(p2.health == hp, "frozen attacker's live hitbox makes no contact")
	# Frozen victim, unfrozen attacker: hit lands.
	d = _new_match()
	p1 = d.fighters[0]
	p2 = d.fighters[1]
	p2.hitstop = 60
	_src(d, 0).press(0, B.LIGHT)
	var hit := _run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	_check(hit, "a frozen victim can still be hit by an unfrozen source")


## Combo damage scaling counts the victim's hits taken from any attacker.
## P1 opens the combo, the victim's count is raised to the scaling threshold
## (standing in for a long combo), then slot 2 lands its first hit: scaled,
## although slot 2's own combo is just 1.
func _test_victim_side_scaling() -> void:
	var d := _new_match(3, 1.4, Vector3(0, 0, -1.9))
	var p1 := d.fighters[0]
	var p2 := d.fighters[1]
	var p3 := d.fighters[2]
	var t := p1.tuning
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	_check(p2._combo_hits_taken == 1, "victim counts the hit taken (%d)" % p2._combo_hits_taken)
	p2._combo_hits_taken = t.combo_scaling_start_hit
	p2._state_len = 500  # keep the victim reeling
	_src(d, 2).press_at_tick(d.tick + 1, B.HEAVY)
	p1.global_position = Vector3(0, 0, 4)  # out of slot 2's reach (one activation hits one fighter)
	var landed := _run_until(d, func() -> bool: return _event_count(&"hit", 1) == 2, 60)
	var dmg := _hit_damages(1)
	var heavy: MoveData = p3.current_move()
	var ok := landed and heavy != null and is_equal_approx(dmg[1], heavy.damage * (1.0 - t.combo_scaling_step))
	_check(ok, "second attacker's hit is scaled by the victim's combo (%s)" % [dmg])
	_check(p3.combo_hits == 1 and p1.combo_hits == 1, "each attacker still shows its own combo (%d / %d)" % [p1.combo_hits, p3.combo_hits])
	_check(p2._combo_hits_taken == t.combo_scaling_start_hit + 1, "count spans attackers (%d)" % p2._combo_hits_taken)


## Hitstop and world freeze round-trip through save/load.
func _test_save_load() -> void:
	var d := _new_match()
	_src(d, 0).press(0, B.LIGHT)
	_run_until(d, func() -> bool: return _event_count(&"hit", 1) == 1, 30)
	d.request_world_freeze(3)
	var s := d.save_state()
	var stop := d.fighters[0].hitstop_left()
	for i in 20:
		d.step()
	d.load_state(s)
	_check(d.world_freeze == 3 and d.fighters[0].hitstop_left() == stop and d.fighters[1].hitstop_left() == stop,
		"hitstop and world freeze survive save/load")
