extends Node
## Headless tests for co-op attack coordination (EncounterDirector) and the
## CPU crowd behaviour built on it (CpuBrain target choice, tokens, tokenless
## hovering): token caps per player, every enemy attack started with a token,
## grab lock, releases (KO, timeout), grant order, determinism, enemies
## spreading over two players, InputFrame.target_request, target stickiness
## and save/load. Run as a scene:
##   godot --headless res://tests/encounter_test.tscn
##
## The encounter is switched on by hand (director.encounter.enabled) on an
## ordinary match, so these tests don't depend on the co-op run flow.

const K := EncounterDirector.Kind
const S := Fighter.State

var _failures := 0
var _prev_state := {}


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_disabled_grants_everything, _test_token_caps_in_a_crowd, _test_grab_lock,
		_test_release_on_ko_and_timeout, _test_grant_order, _test_deterministic_grants,
		_test_enemies_spread_over_two_players, _test_target_request, _test_target_stickiness,
		_test_save_load,
	]
	for t in tests:
		t.call()
	print("ENCOUNTER TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Match in FIGHT with `humans` scripted team-0 fighters (slots 0..) and
## `enemies` team-1 fighters (CPU brains at `level` when `cpu`, else
## scripted). Infinite timer; tokens on.
func _new_match(humans: int, enemies: int, cpu: bool, level: int = 7, seed_value: int = 11) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.rng_seed = seed_value
	for i in humans + enemies:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = 0 if i < humans else 1
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = level
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	d.encounter.enabled = true
	for i in humans + enemies:
		if i < humans or not cpu:
			d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for s in d.sources:
		if s is ScriptedInput:
			(s as ScriptedInput).start_tick = d.tick + 1
	return d


## Step once; humans never go down (the crowd keeps attacking them).
func _step(d: MatchDirector, humans: int) -> void:
	d.step()
	for i in humans:
		var f := d.fighters[i]
		f.health = f.tuning.max_health


func _ko(f: Fighter) -> void:
	f.health = 0.0
	f._enter_ko(Vector3.ZERO)


## Request a token for `a` on `v` and step so it is granted.
func _grant(d: MatchDirector, a: Fighter, v: Fighter, kind: int) -> bool:
	d.encounter.request_token(a, v, kind)
	d.step()
	return d.encounter.request_token(a, v, kind)


# --- tests --------------------------------------------------------------------

func _test_disabled_grants_everything() -> void:
	var d := _new_match(1, 3, false)
	d.encounter.enabled = false
	var f := d.fighters
	var all := true
	for i in range(1, 4):
		all = all and d.encounter.request_token(f[i], f[0], K.MELEE) and d.encounter.request_grab(f[i], f[0])
	_check(all, "disabled: every token and grab request is granted")
	d.encounter.enabled = true
	_check(d.encounter.request_token(f[0], f[1], K.MELEE), "team-0 attackers are never limited")


## Strong CPUs swarm one idle player for 30 s: never more than the caps hold
## tokens, and every attack an enemy starts on the player is backed by one.
func _test_token_caps_in_a_crowd() -> void:
	var d := _new_match(1, 4, true)
	var f := d.fighters
	var c := Tuning.coop
	var over := 0
	var unbacked := 0
	var attacks := 0
	var max_melee := 0
	var serials := {}
	_prev_state.clear()
	for n in 1800:
		_step(d, 1)
		var melee := d.encounter.holders(f[0], K.MELEE).size()
		max_melee = maxi(max_melee, melee)
		if melee > c.melee_tokens_per_player or d.encounter.holders(f[0], K.RANGED).size() > c.ranged_tokens_per_player:
			over += 1
		for i in range(1, 5):
			var e := f[i]
			if e.state != S.ATTACK:
				serials.erase(i)
				continue
			var serial := e.current_move_serial()
			if serials.get(i, -1) == serial:
				continue
			serials[i] = serial
			# Only attacks started from neutral (a string's next move, or one
			# after a teleport chase, continues the attack the token was for).
			if e.target != f[0] or _prev_state.get(i, S.IDLE) in [S.ATTACK, S.TELEPORT]:
				continue
			attacks += 1
			if not (d.encounter.holds_token(e, K.MELEE) or d.encounter.holds_token(e, K.RANGED)):
				unbacked += 1
		for i in range(1, 5):
			_prev_state[i] = f[i].state
	_check(over == 0, "token caps never exceeded (%d ticks over)" % over)
	_check(attacks > 10, "the crowd attacks (%d attacks started)" % attacks)
	_check(unbacked == 0, "every enemy attack on the player started with a token (%d without)" % unbacked)
	_check(max_melee == c.melee_tokens_per_player, "the melee pool gets used up (max %d holders)" % max_melee)


func _test_grab_lock() -> void:
	var d := _new_match(1, 2, false)
	var f := d.fighters
	var enc := d.encounter
	_check(enc.request_grab(f[1], f[0]), "first grabber gets the lock")
	_check(not enc.request_grab(f[2], f[0]), "a second grabber is refused")
	_check(enc.request_grab(f[1], f[0]) and enc.grab_holder(f[0]) == 1, "the holder keeps it")
	enc.release_grab(f[1])
	_check(enc.request_grab(f[2], f[0]), "after release the other enemy may grab")
	for n in Tuning.coop.token_unused_frames + 2:
		d.step()
	_check(enc.grab_holder(f[0]) == -1, "an unused grab lock expires")


func _test_release_on_ko_and_timeout() -> void:
	var d := _new_match(1, 2, false)
	var f := d.fighters
	var enc := d.encounter
	_check(_grant(d, f[1], f[0], K.MELEE), "token granted on the next tick")
	_check(not enc.request_token(f[1], f[0], K.RANGED), "ranged is a separate pool (queued, not granted yet)")
	_ko(f[1])
	d.step()
	_check(not enc.holds_token(f[1], K.MELEE) and enc.holders(f[0], K.MELEE).is_empty(), "a KO'd holder's token returns")
	_check(_grant(d, f[2], f[0], K.MELEE), "granted to the other enemy")
	for n in Tuning.coop.token_unused_frames + 1:
		d.step()
	_check(not enc.holds_token(f[2], K.MELEE), "an unused token times out")
	var d2 := _new_match(2, 1, false)
	var g := d2.fighters
	g[2].target = g[0]
	_check(_grant(d2, g[2], g[0], K.MELEE), "granted on player 1")
	var fr := InputFrame.new()
	fr.target_request = 1
	g[2].feed_input(fr)
	d2.step()
	_check(g[2].target == g[1] and not d2.encounter.holds_token(g[2], K.MELEE), "changing target gives the token back")


func _test_grant_order() -> void:
	var d := _new_match(1, 4, false)
	var f := d.fighters
	var enc := d.encounter
	_grant(d, f[1], f[0], K.MELEE)
	_grant(d, f[2], f[0], K.MELEE)
	enc.request_token(f[4], f[0], K.MELEE)  # waits first
	d.step()
	enc.request_token(f[3], f[0], K.MELEE)
	enc.request_token(f[4], f[0], K.MELEE)
	_ko(f[1])
	d.step()
	_check(enc.holds_token(f[4], K.MELEE) and not enc.holds_token(f[3], K.MELEE),
		"the longest wait wins over the lower slot")
	var d2 := _new_match(1, 4, false)
	var g := d2.fighters
	for i in [4, 3, 2]:
		d2.encounter.request_token(g[i], g[0], K.MELEE)
	d2.step()
	_check(d2.encounter.holders(g[0], K.MELEE) == [2, 3], "same wait: lower slots first (%s)" % [d2.encounter.holders(g[0], K.MELEE)])


func _grant_log(seed_value: int) -> Array:
	var d := _new_match(1, 4, true, 7, seed_value)
	var log: Array = []
	for n in 900:
		_step(d, 1)
		log.append([d.encounter.holders(d.fighters[0], K.MELEE), d.encounter.holders(d.fighters[0], K.RANGED)])
	return log


func _test_deterministic_grants() -> void:
	var a := _grant_log(5)
	var b := _grant_log(5)
	_check(a == b, "same seed -> identical token grants over 15 s")


## Two players apart: the crowd splits instead of all piling on one.
func _test_enemies_spread_over_two_players() -> void:
	var d := _new_match(2, 4, true)
	var f := d.fighters
	f[0].global_position = Vector3(-4, 0, 3)
	f[1].global_position = Vector3(4, 0, 3)
	var both := 0
	var ticks := 1200
	for n in ticks:
		_step(d, 2)
		var on := [0, 0]
		for i in range(2, 6):
			if f[i].target == f[0]:
				on[0] += 1
			elif f[i].target == f[1]:
				on[1] += 1
		if on[0] > 0 and on[1] > 0:
			both += 1
	_check(both > ticks / 2, "enemies cover both players most of the time (%d / %d ticks)" % [both, ticks])


func _test_target_request() -> void:
	var d := _new_match(2, 2, false)
	var f := d.fighters
	f[2].target = f[0]
	var fr := InputFrame.new()
	fr.target_request = 1
	f[2].feed_input(fr)
	d.step()
	_check(f[2].target == f[1] and f[2].is_target_locked(), "a valid target_request retargets and locks")
	fr.target_request = 3
	f[2].feed_input(fr)
	d.step()
	_check(f[2].target == f[1], "a request for a teammate is ignored")
	var a := InputFrame.new()
	a.target_request = 4
	_check(InputFrame.from_array(a.to_array()).target_request == 4 and a.equals(a.duplicate_frame()),
		"target_request survives serialization and copies")


## CPU targets don't flicker: after a change a target is kept for at least
## target_min_hold_frames while it stays targetable.
func _test_target_stickiness() -> void:
	var d := _new_match(2, 4, true)
	var f := d.fighters
	f[0].global_position = Vector3(-3, 0, 3)
	f[1].global_position = Vector3(3, 0, 3)
	var last := {}
	var since := {}
	var flicker := 0
	var changes := 0
	for n in 1200:
		_step(d, 2)
		for i in range(2, 6):
			var t := f[i].target.slot if f[i].target else -1
			if last.has(i) and t != last[i]:
				changes += 1
				if n - since[i] < Tuning.cpu.target_min_hold_frames and n > 30:
					flicker += 1
				since[i] = n
			elif not last.has(i):
				since[i] = n
			last[i] = t
	_check(flicker == 0, "no target change within target_min_hold_frames (%d changes, %d too soon)" % [changes, flicker])


func _test_save_load() -> void:
	var d := _new_match(1, 4, true)
	for n in 400:
		_step(d, 1)
	var snap := d.save_state()
	var enc_before := var_to_str(d.encounter.save_state())
	var after: Array = []
	for n in 300:
		_step(d, 1)
		after.append(var_to_str(d.encounter.save_state()))
	var end_state := var_to_str(d.save_state())
	d.load_state(snap)
	_check(var_to_str(d.encounter.save_state()) == enc_before, "encounter state restored by load_state")
	var same := true
	for n in 300:
		_step(d, 1)
		same = same and var_to_str(d.encounter.save_state()) == after[n]
	_check(same and var_to_str(d.save_state()) == end_state, "re-simulated crowd after load is identical")
