extends Node
## Presentation under rollback (SPEC_ONLINE.md §9) without networking: a
## director (auto_step off) + MatchEventHub (auto_confirm off) driven like the
## rollback driver will: save_state, step on, hub.rollback_to + load_state,
## re-simulate with director.resimulating and DIFFERENT inputs, step on.
## Run as a scene:  godot --headless res://tests/net_resim_fx_test.tscn
##   1. same inputs again: no cosmetic event repeats; one confirmed copy
##   2. a mispredicted hit stays played once (ghost); the real one plays late
##      inside late_fx_window; confirmed_event / RunStats see only the real one
##   3. a corrected hit older than the window never plays, but is confirmed
##   4. a KO + match_ended that gets rolled back never reaches MatchScene's
##      match flow; a confirmed one does
##   5. offline (auto_confirm): both streams match the raw fighter events

const B := InputFrame.Btn
const DISTANCE := 1.4
## Ticks stepped while looking for the calibration hit.
const HIT_SEARCH := 60
## Ticks a CPU-vs-CPU match runs for the offline comparison.
const OFFLINE_TICKS := 1500
## Extra ticks past the window for the "too old" case.
const PAST_WINDOW := 3

var _failures := 0
## Immediate fighter_event log: [tick, kind, emitter slot, attacker slot, resimulating].
var _fx: Array = []
var _states: Array = []
## Confirmed log: [tick, kind, data].
var _confirmed: Array = []
var _director_fx: Array = []


func _ready() -> void:
	var dh := _calibrate()
	if _check(dh > 0, "calibration: a LIGHT press hits %d ticks later" % dh):
		_test_same_inputs()
		_test_ghost_and_late(dh)
		_test_too_old(dh)
		_test_ko_rolled_back()
	_test_offline_streams()
	print("NET RESIM FX TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.rounds_to_win = 1
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(p)
	return cfg


func _clear_logs() -> void:
	_fx.clear()
	_states.clear()
	_confirmed.clear()
	_director_fx.clear()


func _log_hub(d: MatchDirector, hub: MatchEventHub) -> void:
	hub.fighter_event.connect(func(f: Fighter, kind: StringName, data: Dictionary) -> void:
		_fx.append([d.tick, kind, f.slot, int(data.get("attacker_slot", -1)), d.resimulating]))
	hub.fighter_state.connect(func(f: Fighter, s: StringName) -> void: _states.append([d.tick, f.slot, s]))
	hub.director_event.connect(func(kind: StringName, _data: Dictionary) -> void: _director_fx.append([d.tick, kind]))
	hub.confirmed_event.connect(func(t: int, kind: StringName, data: Dictionary) -> void:
		_confirmed.append([t, kind, data]))


## Fresh scripted match in FIGHT, fighters DISTANCE apart, hub in online mode
## (auto_confirm off) + RunStats. Returns [director, hub, run_stats].
func _new_match(cfg: MatchConfig = null) -> Array:
	for c in get_children():
		c.queue_free()
	_clear_logs()
	if cfg == null:
		cfg = _config()
	var hub := MatchEventHub.new()
	hub.auto_confirm = false
	add_child(hub)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	hub.bind_director(d)
	var rs := RunStats.new()
	add_child(rs)
	rs.setup(d, hub, cfg)
	d.setup(cfg)
	_script_match(d)
	hub.confirm_through(d.tick)  # intro events are final
	_log_hub(d, hub)
	return [d, hub, rs]


func _script_match(d: MatchDirector) -> void:
	for i in 2:
		d.sources[i] = ScriptedInput.new()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in 2:
		var pos := Vector3(0, 0, DISTANCE * 0.5 if i == 0 else -DISTANCE * 0.5)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		(d.sources[i] as ScriptedInput).start_tick = d.tick + 1


func _src(d: MatchDirector, i: int) -> ScriptedInput:
	return d.sources[i] as ScriptedInput


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


## The rollback driver's sequence: back to first wrong tick `t` (snapshot =
## state after t - 1), re-simulate up to the presented tick.
func _rollback(d: MatchDirector, hub: MatchEventHub, snap: Dictionary, t: int) -> void:
	var presented := d.tick
	hub.rollback_to(t)
	d.load_state(snap)
	d.resimulating = true
	while d.tick < presented:
		d.step()
	d.resimulating = false


func _hits(log: Array, attacker := -2) -> Array:
	var out: Array = []
	for e: Array in log:
		if e[1] == &"hit" and (attacker == -2 or e[3] == attacker):
			out.append(e)
	return out


func _confirmed_kind(kind: StringName, attacker := -2) -> Array:
	var out: Array = []
	for e: Array in _confirmed:
		if e[1] == kind and (attacker == -2 or int((e[2] as Dictionary).get("attacker_slot", -1)) == attacker):
			out.append(e)
	return out


func _damage(rs: RunStats, slot: int) -> float:
	return float(rs.players[slot][RunStats.DAMAGE])


## Ticks from a LIGHT press to its hit at DISTANCE.
func _calibrate() -> int:
	var parts := _new_match()
	var d: MatchDirector = parts[0]
	var press := d.tick + 1
	_src(d, 0).press(0, B.LIGHT)
	_run(d, HIT_SEARCH)
	var h := _hits(_fx, 0)
	return int(h[0][0]) - press if not h.is_empty() else -1


# --- tests --------------------------------------------------------------------

func _test_same_inputs() -> void:
	var parts := _new_match()
	var d: MatchDirector = parts[0]
	var hub: MatchEventHub = parts[1]
	var rs: RunStats = parts[2]
	var snap := d.save_state()
	var t := d.tick + 1
	_src(d, 0).press(0, B.LIGHT)
	_run(d, HIT_SEARCH)
	var fx_before := _fx.duplicate(true)
	var states_before := _states.duplicate(true)
	_check(_hits(_fx, 0).size() == 1, "same inputs: the hit plays once")
	_check(_confirmed.is_empty() and hub.pending_count() > 0, "nothing confirmed before confirm_through")
	_rollback(d, hub, snap, t)
	_check(_fx == fx_before, "same inputs: re-simulation emits no cosmetic event again (%d -> %d)" % [fx_before.size(), _fx.size()])
	_check(_states == states_before, "same inputs: no state entry (swing sound) repeats")
	hub.confirm_through(d.tick)
	_check(_confirmed_kind(&"hit", 0).size() == 1, "one confirmed copy of the hit")
	var dmg := float((_confirmed_kind(&"hit", 0)[0][2] as Dictionary)["damage"]) if _confirmed_kind(&"hit", 0).size() == 1 else -1.0
	_check(is_equal_approx(_damage(rs, 0), dmg), "RunStats counts the confirmed hit once (%.1f vs %.1f)" % [_damage(rs, 0), dmg])
	var ticks_ok := true
	for i in range(1, _confirmed.size()):
		ticks_ok = ticks_ok and int(_confirmed[i][0]) >= int(_confirmed[i - 1][0])
	_check(ticks_ok, "confirmed events arrive in tick order")


func _test_ghost_and_late(dh: int) -> void:
	var w := Tuning.net.late_fx_window
	var parts := _new_match()
	var d: MatchDirector = parts[0]
	var hub: MatchEventHub = parts[1]
	var rs: RunStats = parts[2]
	var snap := d.save_state()
	var t := d.tick + 1
	var hit_tick := t + dh
	# Predicted: P1 attacks. Presented up to w - 2 ticks past the hit.
	_src(d, 0).press(0, B.LIGHT)
	_run(d, dh + w - 2)
	var presented := d.tick
	_check(_hits(_fx, 0).size() == 1, "predicted timeline: P1's hit plays")
	# Corrected: P1 did nothing, P2 attacked.
	_src(d, 0).frames.clear()
	_src(d, 1).press(0, B.LIGHT)
	_rollback(d, hub, snap, t)
	var late := _hits(_fx, 1)
	_check(_hits(_fx, 0).size() == 1, "ghost hit stays played exactly once")
	_check(late.size() == 1 and late[0][4], "the corrected hit plays late, during the resim")
	if late.size() == 1:
		_check(int(late[0][0]) == hit_tick and int(late[0][0]) >= presented - w,
				"late hit tick %d within the window (presented %d, window %d)" % [late[0][0], presented, w])
	var fx_n := _fx.size()
	_run(d, w)
	_check(_hits(_fx).size() == 2 and _fx.size() >= fx_n, "stepping on after the resim: no repeats")
	hub.confirm_through(d.tick)
	_check(_confirmed_kind(&"hit", 0).is_empty(), "confirmed stream drops the ghost hit")
	_check(_confirmed_kind(&"hit", 1).size() == 1, "confirmed stream has the surviving hit")
	_check(_damage(rs, 0) == 0.0, "RunStats never counted the ghost hit (%.1f)" % _damage(rs, 0))


func _test_too_old(dh: int) -> void:
	var w := Tuning.net.late_fx_window
	var parts := _new_match()
	var d: MatchDirector = parts[0]
	var hub: MatchEventHub = parts[1]
	var rs: RunStats = parts[2]
	var snap := d.save_state()
	var t := d.tick + 1
	_run(d, dh + w + PAST_WINDOW)  # predicted: nobody attacks
	var presented := d.tick
	_src(d, 0).press(0, B.LIGHT)
	_rollback(d, hub, snap, t)
	_check(_hits(_fx).is_empty(), "a corrected hit %d ticks old (window %d) does not play" % [presented - (t + dh), w])
	hub.confirm_through(d.tick)
	_check(_confirmed_kind(&"hit", 0).size() == 1, "...but it is confirmed")
	_check(_damage(rs, 0) > 0.0, "...and RunStats counts it")
	# After the resim, new events play normally again.
	_run(d, HIT_SEARCH)
	_script_match(d)
	_src(d, 0).press(0, B.LIGHT)
	_run(d, HIT_SEARCH)
	var fresh := _hits(_fx, 0)
	_check(fresh.size() == 1 and not fresh[0][4], "events after the resim play normally")


func _test_ko_rolled_back() -> void:
	Game.current_config = _config()
	var scene := MatchScene.new()
	add_child(scene)  # _ready builds everything and runs director.setup()
	var d := scene.director
	var hub := scene.hub
	d.auto_step = false
	hub.auto_confirm = false
	_clear_logs()
	_script_match(d)
	hub.confirm_through(d.tick)
	_log_hub(d, hub)
	d.fighters[1].health = 1.0
	var snap := d.save_state()
	var t := d.tick + 1
	_src(d, 0).press(0, B.LIGHT)
	var ended := [false]
	var on_end := func(_w: int) -> void: ended[0] = true
	d.match_ended.connect(on_end)
	var limit := HIT_SEARCH + Tuning.match_rules.round_outro_frames + 10
	while not ended[0] and d.tick < t + limit:
		d.step()
	_check(ended[0], "predicted timeline: P1 KOs P2 and the match ends (tick %d)" % d.tick)
	_check(_director_fx.any(func(e: Array) -> bool: return e[1] == &"round_ended"), "the KO's round_ended reached the immediate stream")
	_check(not scene.is_ending(), "unconfirmed match_ended does not start the results transition")
	_check(scene.hud.announcer.text != Tuning.hud.text_ko, "unconfirmed KO not announced")
	_src(d, 0).frames.clear()
	_rollback(d, hub, snap, t)
	hub.confirm_through(d.tick)
	_check(d.phase == MatchDirector.Phase.FIGHT, "corrected timeline: still fighting")
	_check(_confirmed_kind(&"round_ended").is_empty() and _confirmed_kind(&"match_ended").is_empty()
			and _confirmed_kind(&"ko").is_empty(), "rolled-back KO / round / match end never confirmed")
	_check(not scene.is_ending(), "rolled-back match_ended never reaches the match flow")
	# Control: the same KO, confirmed this time, does end the match.
	_src(d, 0).press_at_tick(d.tick + 1, B.LIGHT)
	ended[0] = false
	var t2 := d.tick
	while not ended[0] and d.tick < t2 + limit:
		d.step()
	hub.confirm_through(d.tick)
	_check(_confirmed_kind(&"match_ended").size() == 1 and scene.is_ending(), "a confirmed match_ended starts the results transition")
	d.match_ended.disconnect(on_end)
	scene.queue_free()


## Offline: immediate stream = raw fighter events (minus same-tick duplicate
## hits), confirmed stream = the same sequence, director events in step.
func _test_offline_streams() -> void:
	for c in get_children():
		c.queue_free()
	_clear_logs()
	var cfg := _config()
	cfg.rounds_to_win = 2
	cfg.round_time_seconds = 20
	for p in cfg.players:
		p.cpu_level = Tuning.cpu.level_names.size() - 1
	var hub := MatchEventHub.new()
	add_child(hub)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	hub.bind_director(d)
	_log_hub(d, hub)
	var raw: Array = []
	var raw_keys: Array = []  # old hub's hit content key per raw event
	var raw_dir: Array = []
	var hook := func(fs: Array[Fighter]) -> void:
		for f in fs:
			f.event.connect(func(kind: StringName, data: Dictionary) -> void:
				raw.append([d.tick, kind, f.slot, int(data.get("attacker_slot", -1)), false])
				raw_keys.append("%d|%s|%s|%s" % [d.tick, data.get("attacker_slot", -1),
						data.get("position", Vector3.INF), data.get("damage", 0)]))
	d.fighters_spawned.connect(hook)
	d.round_ended.connect(func(_w: int, _r: StringName) -> void: raw_dir.append([d.tick, &"round_ended"]))
	d.match_ended.connect(func(_w: int) -> void: raw_dir.append([d.tick, &"match_ended"]))
	d.round_started.connect(func(_n: int) -> void: raw_dir.append([d.tick, &"round_started"]))
	d.setup(cfg)
	for i in OFFLINE_TICKS:
		if d.phase == MatchDirector.Phase.MATCH_OVER:
			break
		d.step()
	# Old hub behaviour: drop a hit identical to one already seen in that tick.
	var expected: Array = []
	var seen := {}
	for i in raw.size():
		var e: Array = raw[i]
		if e[1] == &"hit":
			if seen.has(raw_keys[i]):
				continue
			seen[raw_keys[i]] = true
		expected.append(e)
	_check(expected.size() > 10 and _fx == expected, "offline: immediate stream == raw fighter events (%d vs %d)" % [_fx.size(), expected.size()])
	var conf_fighter: Array = []
	var conf_dir: Array = []
	for e: Array in _confirmed:
		var data: Dictionary = e[2]
		if int(data["sim_id"]) == MatchEventHub.DIRECTOR_SIM_ID:
			if e[1] in [&"round_ended", &"match_ended", &"round_started"]:
				conf_dir.append([e[0], e[1]])
		else:
			conf_fighter.append([e[0], e[1], int(data["slot"]), int(data.get("attacker_slot", -1)), false])
	_check(conf_fighter == expected, "offline: every event confirmed at once, same order")
	_check(conf_dir == raw_dir and not raw_dir.is_empty(), "offline: director flow confirmed in step (%s)" % [raw_dir])
	_check(hub.pending_count() == 0, "offline: nothing left buffered")
