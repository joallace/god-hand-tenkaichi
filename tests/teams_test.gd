extends Node
## Headless tests for the team model: team assignment, default targets, spawn
## layout, friendly fire, team-aware round end, partner tracking in throws,
## target save/load, Fighter targeting (TARGET cycle, manual lock, auto
## re-pick, deferral, free roam toggle + quick turn) and per-victim contacts (cleaving strikes, piercing
## beams, single-target blasts and throws). Run as a scene:
##   godot --headless res://tests/teams_test.tscn

const B := InputFrame.Btn

var _failures := 0
var _round_end: Array = []  # [winner_slot, reason]


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_1v1_spawn_unchanged, _test_2v2_setup, _test_friendly_fire,
		_test_team_round_end, _test_time_out_mean_health, _test_throw_partner,
		_test_target_save_load, _test_target_cycle_and_lock, _test_lock_drops_on_ko,
		_test_auto_prefers_front_and_attacker, _test_no_switch_mid_dodge,
		_test_targeting_vars_save_load, _test_free_roam, _test_heavy_cleaves, _test_cleave_skips_ally,
		_test_ki_blast_single_target, _test_beam_pierces, _test_throw_grabs_one,
	]
	for t in tests:
		t.call()
	print("TEAMS TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in the FIGHT phase with one fighter per entry of `teams` (its team
## id), all driven by ScriptedInput.
func _new_match(teams: Array[int], friendly_fire: bool = false, seconds: int = 0) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_round_end.clear()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = seconds
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
	d.round_ended.connect(func(w: int, r: StringName) -> void: _round_end.append([w, r]))
	d.setup(cfg)
	for i in teams.size():
		d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in teams.size():
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1
	return d


## Place fighters at `positions` (facing -Z) and re-pick default targets.
func _place(d: MatchDirector, positions: Array[Vector3]) -> void:
	for i in positions.size():
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(Vector3.FORWARD), positions[i]))
	for f in d.fighters:
		f.target = d.pick_default_target(f)


func _src(d: MatchDirector, slot: int) -> ScriptedInput:
	return d.sources[slot] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _ko(f: Fighter) -> void:
	f.health = 0.0
	f._enter_ko(Vector3.ZERO)


# --- tests --------------------------------------------------------------------

func _test_1v1_spawn_unchanged() -> void:
	var d := _new_match([-1, -1])
	var half := Tuning.match_rules.spawn_distance * 0.5
	var ok := true
	for i in 2:
		var pos := Vector3(0, 0, half if i == 0 else -half)
		var want := Transform3D(Basis.looking_at(-pos.normalized()), pos)
		var got := d.spawn_transform(i)
		ok = ok and got.origin == want.origin and got.basis == want.basis
	_check(ok, "1v1 spawn transforms identical to the pre-teams layout")
	_check(d.fighters[0].team == 0 and d.fighters[1].team == 1, "team -1 defaults to the slot")
	_check(d.fighters[0].target == d.fighters[1] and d.fighters[1].target == d.fighters[0], "1v1 fighters target each other")
	_check(d.wins.size() == 2, "wins sized per team")


func _test_2v2_setup() -> void:
	var d := _new_match([0, 0, 1, 1])
	var f := d.fighters
	_check(f[0].team == 0 and f[1].team == 0 and f[2].team == 1 and f[3].team == 1, "2v2 teams assigned from config")
	var enemies := true
	for x in f:
		enemies = enemies and x.target != null and x.target.team != x.team
	_check(enemies, "every fighter starts targeting an enemy")
	var sides := true
	for i in 4:
		var p := d.spawn_transform(i).origin
		sides = sides and (p.z > 0.0 if f[i].team == 0 else p.z < 0.0)
	_check(sides, "teams spawn on opposite sides of the ring")
	var gap := d.spawn_transform(0).origin.distance_to(d.spawn_transform(1).origin)
	_check(is_equal_approx(gap, Tuning.match_rules.spawn_team_spacing), "teammates spawn spawn_team_spacing apart (%.2f)" % gap)
	_check(d.wins.size() == 2, "2v2 wins sized per team")


func _test_friendly_fire() -> void:
	for ff: bool in [false, true]:
		var d := _new_match([0, 0, 1], ff)
		# Teammate right in front of slot 0, the enemy far behind it in line.
		_place(d, [Vector3(0, 0, 0.7), Vector3(0, 0, -0.7), Vector3(0, 0, -12)])
		var mate := d.fighters[1]
		_src(d, 0).press(2, B.LIGHT)
		_run(d, 40)
		var hurt := mate.health < mate.tuning.max_health
		if ff:
			_check(hurt, "friendly fire on: a teammate's jab hurts (hp %.1f)" % mate.health)
		else:
			_check(not hurt, "friendly fire off: teammates can't hit each other (hp %.1f)" % mate.health)


func _test_team_round_end() -> void:
	var d := _new_match([0, 0, 1, 1])
	var f := d.fighters
	_place(d, [Vector3(-1, 0, 3), Vector3(1, 0, 3), Vector3(-1, 0, -3), Vector3(5, 0, -3)])
	_check(f[0].target == f[2], "slot 0 targets the nearest enemy (slot 2)")
	_ko(f[2])
	_run(d, 2)
	_check(d.phase == MatchDirector.Phase.FIGHT, "round goes on while a team member stands")
	_check(f[0].target == f[3], "target re-picked when it is KO'd (now slot %d)" % (f[0].target.slot if f[0].target else -1))
	_ko(f[3])
	_run(d, 2)
	_check(d.phase == MatchDirector.Phase.OUTRO, "round ends when a whole team is KO")
	_check(d.last_winner_team == 0 and d.wins[0] == 1 and d.wins[1] == 0, "winning team credited (team %d)" % d.last_winner_team)
	_check(not _round_end.is_empty() and _round_end[0][0] == 0 and _round_end[0][1] == &"ko", "round_ended reports the team's lowest slot: %s" % [_round_end])
	_check(d.wins_for_slot(1) == 1 and d.wins_for_slot(3) == 0, "wins_for_slot reads the slot's team")


func _test_time_out_mean_health() -> void:
	var d := _new_match([0, 0, 1, 1], false, 1)
	var f := d.fighters
	_place(d, [Vector3(-1, 0, 6), Vector3(1, 0, 6), Vector3(-1, 0, -6), Vector3(1, 0, -6)])
	# Team 0 has the healthiest fighter but mean 0.5; team 1 mean 0.6 wins.
	f[0].health = f[0].tuning.max_health * 0.9
	f[1].health = f[1].tuning.max_health * 0.1
	f[2].health = f[2].tuning.max_health * 0.6
	f[3].health = f[3].tuning.max_health * 0.6
	_run(d, Tuning.match_rules.tick_rate + 5)
	_check(d.last_winner_team == 1 and not _round_end.is_empty() and _round_end[0] == [2, &"time"],
		"time-out: best mean team health wins (%s)" % [_round_end])


func _test_throw_partner() -> void:
	# Slot 0 throws slot 2, whose own target is slot 1 (not the thrower).
	var d := _new_match([0, 0, 1])
	var f := d.fighters
	_place(d, [Vector3(0, 0, 0.7), Vector3(3, 0, -2), Vector3(0, 0, -0.7)])
	f[2].target = f[1]
	_src(d, 0).press(4, B.THROW)
	var grabbed := false
	for i in 30:
		d.step()
		if f[2].current_state_name() == &"thrown":
			grabbed = true
			break
	_check(grabbed and f[0].current_state_name() == &"throw", "throw grabs a victim that targets someone else")
	d.step()
	var hold := f[2].global_position.distance_to(f[0].global_position)
	_check(f[2].current_state_name() == &"thrown" and absf(hold - f[2].tuning.throw_hold_distance) < 0.05,
		"thrown victim is held by its thrower, not its target (%.2f m)" % hold)
	var down := false
	for i in 40:
		d.step()
		if f[2].current_state_name() == &"knockdown":
			down = true
			break
	_check(down and f[2].health < f[2].tuning.max_health and f[1].health == f[1].tuning.max_health,
		"throw executes on the held victim")


func _test_target_save_load() -> void:
	var d := _new_match([0, 0, 1, 1])
	var f := d.fighters
	f[0].target = f[3]
	var s := d.save_state()
	f[0].target = f[2]
	f[2].team = 7
	d.load_state(s)
	_check(f[0].target == f[3] and f[2].team == 1, "target and team round-trip through save/load")
	f[0].target = null
	s = d.save_state()
	f[0].target = f[2]
	d.load_state(s)
	_check(f[0].target == null, "null target round-trips")


# --- Fighter targeting (1v2: slot 0 vs slots 1 and 2) ---------------------------

## P1 at the origin facing -Z, enemies front-left (slot 1) and front-right
## (slot 2), mirror images, so auto picks break ties to slot 1.
func _new_1v2() -> MatchDirector:
	var d := _new_match([0, 1, 1])
	_place(d, [Vector3.ZERO, Vector3(-2, 0, -4), Vector3(2, 0, -4)])
	return d


func _test_target_cycle_and_lock() -> void:
	var d := _new_1v2()
	var f := d.fighters
	_check(f[0].target == f[1] and not f[0].is_target_locked(), "1v2 default target is the lower slot, unlocked")
	# A tap acts when let go (the stick is read on the press).
	_src(d, 0).press(0, B.TARGET).press(4, B.TARGET).stick(4, 5, Vector2(-1, 0))
	_run(d, 1)
	_check(f[0].target == f[1], "TARGET tap waits for the release")
	_run(d, 1)
	_check(f[0].target == f[2] and f[0].is_target_locked(), "TARGET (stick neutral) cycles clockwise and locks")
	_run(d, 4)
	_check(f[0].target == f[1] and f[0].is_target_locked(), "TARGET + stick left cycles counter-clockwise")
	# Make slot 2 the obvious auto pick (dead ahead, close); the lock holds.
	f[2].global_position = f[0].global_position + f[0]._fwd() * 1.5
	f[1].global_position = f[0].global_position - f[0]._fwd() * 6.0
	_run(d, Tuning.targeting.retarget_check_frames * 3)
	_check(f[0].target == f[1] and f[0].is_target_locked(), "manual lock persists through auto checks")


func _test_lock_drops_on_ko() -> void:
	var d := _new_1v2()
	var f := d.fighters
	_src(d, 0).press(0, B.TARGET)
	_run(d, 2)
	_check(f[0].target == f[2] and f[0].is_target_locked(), "locked on slot 2")
	_ko(f[2])
	_run(d, 2)
	_check(f[0].target == f[1] and not f[0].is_target_locked(), "lock drops and auto re-picks when the target is KO'd")


func _test_auto_prefers_front_and_attacker() -> void:
	var d := _new_match([0, 1, 1])
	var f := d.fighters
	_place(d, [Vector3.ZERO, Vector3(0, 0, 4), Vector3(0, 0, -4)])
	f[0].target = null
	_run(d, 1)
	_check(f[0].target == f[2], "auto pick prefers the enemy in front over the one behind")
	_place(d, [Vector3.ZERO, Vector3(-2, 0, -4), Vector3(2, 0, -4)])
	f[2].target = f[0]
	_src(d, 2).press(d.tick + 1 - _src(d, 2).start_tick, B.LIGHT)
	_run(d, 1)
	f[0]._set_yaw(0.0)  # mirror-symmetric again
	_check(f[2].attack_phase() >= 0 and f[0].best_target() == f[2],
		"auto pick prefers the enemy attacking me (state %s)" % f[2].current_state_name())


func _test_no_switch_mid_dodge() -> void:
	var d := _new_1v2()
	var f := d.fighters
	_src(d, 0).flick(0, InputFrame.Dodge.LEFT).press(2, B.TARGET)
	_run(d, 4)
	var dodging := f[0].state == Fighter.State.DODGE
	_check(dodging and f[0].target == f[1], "no target change mid dodge (state %s)" % f[0].current_state_name())
	var n := 0
	while f[0].state == Fighter.State.DODGE and n < 120:
		_run(d, 1)
		n += 1
	_run(d, 1)
	_check(f[0].target == f[2] and f[0].is_target_locked(), "deferred TARGET tap applies after the dodge")


func _test_targeting_vars_save_load() -> void:
	var d := _new_1v2()
	var f := d.fighters
	_src(d, 0).flick(0, InputFrame.Dodge.LEFT).press(2, B.TARGET)
	_run(d, 4)
	var before: Dictionary = f[0].save_state()
	_check(before["target_press_pending"], "a deferred TARGET tap is pending mid dodge")
	var s := d.save_state()
	f[0]._target_press_pending = false
	f[0]._target_locked = true
	f[0]._retarget_timer = 99
	f[0]._target_press_dir = -1
	d.load_state(s)
	var after: Dictionary = f[0].save_state()
	var ok := true
	for k in ["target_locked", "retarget_timer", "target_press_pending", "target_press_dir", "target"]:
		ok = ok and before[k] == after[k]
	_check(ok, "targeting vars round-trip through save/load")


## Angle (rad) between `f`'s facing and the direction to its target.
func _off_target(f: Fighter) -> float:
	var to := f.target.global_position - f.global_position
	to.y = 0.0
	return f._fwd().angle_to(to)


func _test_free_roam() -> void:
	var d := _new_match([0, 1])
	_place(d, [Vector3.ZERO, Vector3(0, 0, -4)])
	var f := d.fighters
	var hold := Tuning.targeting.free_roam_hold_frames
	var turn := 30
	# Hold TARGET 90 frames: stick right (turn), then stick up (walk).
	_src(d, 0).press(0, B.TARGET, 90).stick(hold, hold + turn, Vector2(1, 0)) \
		.stick(hold + turn, 90, Vector2(0, 1))
	_run(d, hold - 1)
	_check(not f[0].is_free_roaming(), "TARGET held < free_roam_hold_frames is not free roam yet")
	_run(d, 1)
	_check(f[0].is_free_roaming(), "TARGET held free_roam_hold_frames = free roam")
	var yaw0: float = f[0]._yaw
	_run(d, turn)
	var want := DetMath.deg_to_rad(f[0].tuning.free_roam_turn_speed_deg) * turn / Tuning.match_rules.tick_rate
	_check(absf(wrapf(yaw0 - f[0]._yaw, -PI, PI) - want) < 0.01,
		"stick right turns clockwise at free_roam_turn_speed_deg (%.3f vs %.3f rad)" % [wrapf(yaw0 - f[0]._yaw, -PI, PI), want])
	var p0: Vector3 = f[0].global_position
	_run(d, 90 - hold - turn)
	var moved: Vector3 = f[0].global_position - p0
	_check(_off_target(f[0]) > deg_to_rad(90.0), "no auto-facing while free roaming (%.0f deg off)" % rad_to_deg(_off_target(f[0])))
	_check(moved.length() > 1.0 and moved.normalized().dot(f[0]._fwd()) > 0.99,
		"stick up walks along the facing (%.2f m)" % moved.length())
	var s: Dictionary = f[0].save_state()
	_check(s["target_hold"] == hold and s["free_roam"], "free roam is in save_state")
	_run(d, 30)
	_check(f[0].is_free_roaming() and not f[0].is_target_locked() and _off_target(f[0]) > deg_to_rad(90.0),
		"letting go keeps free roam on (a toggle), without a target cycle")

	# Tap in free roam = quick 180 degree turn (on release), not a cycle.
	var q: int = f[0].tuning.free_roam_quick_turn_frames
	var yaw1: float = f[0]._yaw
	_src(d, 0).press(120, B.TARGET)
	_run(d, 2)
	_check(f[0]._quick_turn_left > 0, "a TARGET tap in free roam starts a quick turn")
	var snap := d.save_state()
	var mid: Dictionary = f[0].save_state()
	_run(d, q)
	_check(absf(absf(wrapf(f[0]._yaw - yaw1, -PI, PI)) - PI) < 0.01 and f[0].is_free_roaming()
		and not f[0].is_target_locked(), "the quick turn ends facing the other way, still free roaming")
	d.load_state(snap)
	var back: Dictionary = f[0].save_state()
	var ok := true
	for k in ["free_roam", "quick_turn_buf", "quick_turn_left", "target_hold"]:
		ok = ok and back[k] == mid[k]
	_check(ok, "free roam / quick turn vars round-trip through save/load")
	_run(d, q)

	# An attack started mid-turn finishes the turn at once.
	_run(d, 140 - (122 + q))
	var yaw2: float = f[0]._yaw
	_src(d, 0).press(140, B.TARGET).press(143, B.LIGHT)
	_run(d, 4)
	_check(f[0].state == Fighter.State.ATTACK and absf(absf(wrapf(f[0]._yaw - yaw2, -PI, PI)) - PI) < 0.01,
		"an attack mid quick turn snaps the rest of the turn (state %s)" % f[0].current_state_name())

	# Holding TARGET again toggles free roam off; the fighter faces its target.
	_run(d, 60)
	_src(d, 0).press(204, B.TARGET, hold + 5)
	_run(d, hold + 6)
	_check(not f[0].is_free_roaming() and not f[0].is_target_locked(), "holding TARGET again toggles free roam off")
	_run(d, 60)
	_check(_off_target(f[0]) < deg_to_rad(2.0), "after free roam the fighter turns back to its target")


func _hurt(f: Fighter) -> bool:
	return f.health < f.tuning.max_health


## Slot 0 at the origin facing -Z; slot 1 (nearest, its target) straight
## ahead, slot 2 beside it, both inside the mid kick's sphere.
const PAIR_FRONT: Array[Vector3] = [Vector3(0, 0, 0), Vector3(0, 0, -0.95), Vector3(0.88, 0, -0.95)]


func _test_heavy_cleaves() -> void:
	var d := _new_match([0, 1, 1])
	_place(d, PAIR_FRONT)
	_src(d, 0).press(2, B.HEAVY)
	_run(d, 40)
	_check(_hurt(d.fighters[1]) and _hurt(d.fighters[2]),
		"one heavy hits both adjacent enemies (hp %.1f / %.1f)" % [d.fighters[1].health, d.fighters[2].health])
	_check(d.fighters[0].combo_hits == 2, "each victim counts as a hit (combo %d)" % d.fighters[0].combo_hits)
	var a := d.fighters[0]
	var st := a.save_state()
	a.clear_contacts()
	a.load_state(st)
	_check(a._contacted_slots == PackedInt32Array([1, 2]) and a._last_contact_id == st["last_contact"],
		"per-victim contacts round-trip save/load (%s)" % [a._contacted_slots])


func _test_cleave_skips_ally() -> void:
	var d := _new_match([0, 0, 1])
	_place(d, PAIR_FRONT)
	_src(d, 0).press(2, B.HEAVY)
	_run(d, 40)
	_check(_hurt(d.fighters[2]) and not _hurt(d.fighters[1]),
		"friendly fire off: the cleave hits the enemy, not the ally beside it")


func _test_ki_blast_single_target() -> void:
	var d := _new_match([0, 1, 1])
	_place(d, [Vector3(0, 0, 6), Vector3(-0.46, 0, 0), Vector3(0.46, 0, 0)])
	_src(d, 0).press(2, B.BLAST)
	var blast: KiBlast = null
	for i in 30:
		d.step()
		if not d.entities.is_empty() and d.entities[0] is KiBlast:
			blast = d.entities[0]
			break
	if not _check(blast != null, "ki blast spawned"):
		return
	# Wide enough to touch both enemies on the same tick.
	blast.move = blast.move.duplicate()
	blast.move.hitbox_radius = 1.5
	_run(d, 60)
	var hurt := int(_hurt(d.fighters[1])) + int(_hurt(d.fighters[2]))
	_check(hurt == 1, "a ki blast touching two enemies hits only the first (%d hurt)" % hurt)


func _test_beam_pierces() -> void:
	var d := _new_match([0, 1, 1, 1])
	_place(d, [Vector3(0, 0, 6), Vector3(0, 0, 3), Vector3(0, 0, 1), Vector3(0, 0, -1)])
	d.fighters[0].ki = d.fighters[0].ki_max()
	_src(d, 0).press(2, B.SPECIAL)
	_run(d, 150)
	var all := _hurt(d.fighters[1]) and _hurt(d.fighters[2]) and _hurt(d.fighters[3])
	_check(all, "beam pierces three enemies in a line (hp %.1f / %.1f / %.1f)" % [
		d.fighters[1].health, d.fighters[2].health, d.fighters[3].health])


func _test_throw_grabs_one() -> void:
	var d := _new_match([0, 1, 1])
	_place(d, [Vector3(0, 0, 0), Vector3(-0.46, 0, -0.9), Vector3(0.46, 0, -0.9)])
	_src(d, 0).press(2, B.THROW)
	var thrown := 0
	for i in 30:
		d.step()
		thrown = int(d.fighters[1].current_state_name() == &"thrown") + int(d.fighters[2].current_state_name() == &"thrown")
		if thrown > 0:
			break
	_check(thrown == 1, "a throw grabs one of two enemies in reach (%d grabbed)" % thrown)
