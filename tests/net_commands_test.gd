extends Node
## Sim commands (SPEC_ONLINE.md §7.4) and the plain-data MatchConfig:
## CPU_TAKEOVER / RECLAIM / FORFEIT at a tick survive a rollback across that
## tick (identical StateHash to a straight run), slot_controller round-trips
## through save/load, malformed commands and configs are rejected.
## Run as a scene:  godot --headless res://tests/net_commands_test.tscn

const CK := MatchDirector.CommandKind
const TAKEOVER_AT := 200
const RECLAIM_AT := 400
const END_AT := 520

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_takeover_reclaim_rollback, _test_load_into_takeover, _test_slot_controller_round_trip,
		_test_forfeit_rollback, _test_forfeit_ffa_winner, _test_forfeit_coop_ignored,
		_test_command_validation, _test_join_stub,
		_test_config_round_trip, _test_config_garbage, _test_player_tag_and_localize,
	]
	for t in tests:
		t.call()
	print("NET COMMANDS TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Versus with `teams` fighters (one per team): slot 0 a human fed by
## TickInput (through source_factory), the rest CPUs.
func _new_match(teams: int = 2, seed_value: int = 7) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 0
	cfg.rng_seed = seed_value
	for i in teams:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL if i == 0 else PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 2
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		return TickInput.new(seed_value) if p.input_kind != PlayerSlotConfig.InputKind.CPU else p.create_input_source()
	add_child(d)
	d.setup(cfg)
	return d


func _run_to(d: MatchDirector, t: int) -> void:
	while d.tick < t:
		d.step()


func _takeover_cmds(d: MatchDirector) -> void:
	d.add_command({"tick": TAKEOVER_AT, "kind": CK.CPU_TAKEOVER, "slot": 0, "cpu_level": 1})
	d.add_command({"tick": RECLAIM_AT, "kind": CK.RECLAIM, "slot": 0, "peer": 2})


func _test_takeover_reclaim_rollback() -> void:
	var straight := _new_match()
	_takeover_cmds(straight)
	var f0 := straight.fighters[0]
	_run_to(straight, TAKEOVER_AT - 1)
	_check(straight.sources[0] is TickInput, "slot 0 starts on its player source (source_factory)")
	var state_before := f0.save_state()
	straight.step()
	_check(straight.sources[0] is CpuInput and straight.controller_for_slot(0) == MatchDirector.Controller.CPU,
			"CPU_TAKEOVER at its tick swaps slot 0 to a CpuInput")
	_check(MatchScene.cpu_takeover_slots(straight) == PackedInt32Array([0]),
			"the results extra lists the taken-over human slot")
	_check(straight.fighters[0] == f0 and f0.health <= state_before["health"] and f0.health > 0.0,
			"the fighter (and its health) is kept through the takeover")
	_check((straight.sources[0] as CpuInput).brain.level == 1, "takeover CPU uses the command's level")
	_run_to(straight, RECLAIM_AT)
	_check(straight.sources[0] is TickInput and straight.controller_for_slot(0) == MatchDirector.Controller.PLAYER,
			"RECLAIM gives slot 0 its player source back")
	_check(MatchScene.cpu_takeover_slots(straight).is_empty(), "a reclaimed slot is no longer listed")
	_run_to(straight, END_AT)
	var want := StateHash.of(straight)

	var d := _new_match()
	_takeover_cmds(d)
	_run_to(d, TAKEOVER_AT - 50)
	var before := d.save_state()
	_run_to(d, END_AT)
	_check(StateHash.of(d) == want, "two straight runs with the same commands hash equal")
	d.load_state(before)
	_check(d.sources[0] is TickInput and d.slot_controller[0] == MatchDirector.Controller.PLAYER,
			"load before the takeover restores the player source")
	_run_to(d, END_AT)
	_check(StateHash.of(d) == want, "rollback across CPU_TAKEOVER and RECLAIM re-simulates identically")


## Snapshot taken during the takeover, loaded after the reclaim: the source
## has to become a CpuInput again (with the snapshot's brain state).
func _test_load_into_takeover() -> void:
	var d := _new_match()
	_takeover_cmds(d)
	_run_to(d, TAKEOVER_AT + 60)
	var during := d.save_state()
	_run_to(d, END_AT)
	var want := StateHash.of(d)
	d.load_state(during)
	_check(d.sources[0] is CpuInput and d.slot_controller[0] == MatchDirector.Controller.CPU,
			"load into the takeover recreates the CpuInput")
	_check(var_to_str(d.sources[0].save_state()) == var_to_str(during["sources"][0]), "recreated CPU source carries the saved brain state")
	_run_to(d, END_AT)
	_check(StateHash.of(d) == want, "re-simulation from inside the takeover is identical")


func _test_slot_controller_round_trip() -> void:
	var d := _new_match()
	d.add_command({"tick": 5, "kind": CK.CPU_TAKEOVER, "slot": 0, "cpu_level": 3})
	_run_to(d, 10)
	var s := d.save_state()
	_check(s["slot_controller"] == PackedInt32Array([MatchDirector.Controller.CPU, MatchDirector.Controller.PLAYER])
			and s["takeover_level"][0] == 3, "save_state carries slot_controller and takeover_level")
	_check(StateHash.of_state(s) == StateHash.of(d), "save_state is stable (same hash twice)")
	var d2 := _new_match()
	_run_to(d2, 10)
	d2.load_state(s)
	_check(d2.slot_controller == s["slot_controller"] and d2.takeover_level == s["takeover_level"]
			and d2.sources[0] is CpuInput, "another director loading it takes the CPU controller")
	_check(StateHash.of(d2) == StateHash.of_state(s), "loaded state hashes like the snapshot")
	_check(d2.commands().is_empty() and d.commands().size() == 1, "the command log is not part of the state")


func _test_forfeit_rollback() -> void:
	var ended: Array[int] = []
	var d := _new_match()
	d.match_ended.connect(func(w: int) -> void: ended.append(w))
	d.add_command({"tick": TAKEOVER_AT, "kind": CK.FORFEIT, "team": 0})
	_run_to(d, TAKEOVER_AT - 30)
	var before := d.save_state()
	_run_to(d, TAKEOVER_AT)
	_check(d.phase == MatchDirector.Phase.MATCH_OVER and d.end_reason == &"forfeit" and d.last_winner_team == 1,
			"FORFEIT ends the match at its tick, the other team wins")
	_check(ended == [1], "match_ended carries the winner's slot")
	_run_to(d, TAKEOVER_AT + 40)
	var want := StateHash.of(d)
	d.load_state(before)
	_check(d.phase == MatchDirector.Phase.FIGHT and d.end_reason == &"", "load before the forfeit: match running again")
	_run_to(d, TAKEOVER_AT + 40)
	_check(StateHash.of(d) == want and d.phase == MatchDirector.Phase.MATCH_OVER, "rollback across FORFEIT re-simulates identically")


## Three teams: the winner is the remaining team with most wins, then the
## best health ratio.
func _test_forfeit_ffa_winner() -> void:
	var d := _new_match(3)
	_run_to(d, 100)
	d.fighters[2].health *= 0.5
	d.add_command({"tick": d.tick + 1, "kind": CK.FORFEIT, "team": 0})
	d.step()
	_check(d.phase == MatchDirector.Phase.MATCH_OVER and d.last_winner_team == 1, "FFA forfeit: healthier remaining team wins")
	var d2 := _new_match(3)
	_run_to(d2, 100)
	d2.wins[2] = 1
	d2.fighters[2].health *= 0.5
	d2.add_command({"tick": d2.tick + 1, "kind": CK.FORFEIT, "team": 0})
	d2.step()
	_check(d2.last_winner_team == 2, "FFA forfeit: round wins beat health")


func _test_forfeit_coop_ignored() -> void:
	for c in get_children():
		c.queue_free()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.coop = CoopConfig.new()
	var p := PlayerSlotConfig.new()
	p.input_kind = PlayerSlotConfig.InputKind.CPU
	cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	d.add_command({"tick": 2, "kind": CK.FORFEIT, "team": 0})
	_run_to(d, 3)
	_check(d.phase != MatchDirector.Phase.MATCH_OVER, "FORFEIT is ignored in co-op")


func _test_command_validation() -> void:
	var d := _new_match()
	var bad: Array = [
		{}, {"kind": CK.FORFEIT, "team": 0}, {"tick": 0, "kind": CK.FORFEIT, "team": 0},
		{"tick": 5, "kind": 99}, {"tick": 5, "kind": -1}, {"tick": "5", "kind": CK.FORFEIT, "team": 0},
		{"tick": 5, "kind": CK.CPU_TAKEOVER}, {"tick": 5, "kind": CK.CPU_TAKEOVER, "slot": "0"},
		{"tick": 5, "kind": CK.JOIN, "slot": 2, "peer": 3, "character": 5},
		{"tick": 5.0, "kind": CK.FORFEIT, "team": 0},
	]
	var rejected := 0
	for c: Dictionary in bad:
		if not d.add_command(c):
			rejected += 1
	_check(rejected == bad.size() and d.commands().is_empty(), "malformed commands are rejected (%d/%d)" % [rejected, bad.size()])
	_check(MatchDirector.sanitize_command("junk").is_empty() and MatchDirector.sanitize_command(null).is_empty(), "non-dictionary commands are rejected")
	_check(d.add_command({"tick": 5, "kind": CK.CPU_TAKEOVER, "slot": 0, "extra": [1, 2]}), "valid command accepted")
	var logged := d.commands()[0]
	_check(not logged.has("extra") and logged["cpu_level"] == -1, "unknown args dropped, optional args defaulted")
	d.add_command({"tick": 5, "kind": CK.CPU_TAKEOVER, "slot": 9})
	_run_to(d, 6)
	_check(d.sources[0] is CpuInput and d.fighters.size() == 2, "unknown slot ignored, the valid command applied")


func _test_join_stub() -> void:
	var d := _new_match()
	_check(d.add_command({"tick": 3, "kind": CK.JOIN, "slot": 2, "peer": 3, "character": "brawler", "name": "X"}), "JOIN accepted")
	_run_to(d, 4)
	_check(d.fighters.size() == 2, "JOIN is a no-op until drop-in lands")


# --- MatchConfig plain data ---------------------------------------------------

func _full_config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.rng_seed = 1234567890123
	cfg.round_time_seconds = 0
	cfg.friendly_fire = true
	cfg.arena_id = &"default"
	cfg.coop = CoopConfig.new()
	cfg.coop.structure = CoopConfig.Structure.WAVES
	cfg.coop.endless = true
	cfg.coop.enemy_level = 2
	cfg.coop.ally_enabled = true
	cfg.coop.ally_character = &"brawler"
	for i in 2:
		var w := WaveConfig.new()
		w.count = 3 + i
		w.level = i
		w.character = &"brawler" if i == 0 else &""
		cfg.coop.waves.append(w)
	for i in 3:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.team = 0
		p.input_kind = [PlayerSlotConfig.InputKind.LOCAL, PlayerSlotConfig.InputKind.NETWORK, PlayerSlotConfig.InputKind.CPU][i]
		p.device_kind = 1
		p.device_id = i
		p.cpu_level = 4
		p.owner_peer = [1, 2, 0][i]
		p.display_name = ["Host", "Guest", ""][i]
		cfg.players.append(p)
	return cfg


func _test_config_round_trip() -> void:
	var cfg := _full_config()
	var d := cfg.to_dict()
	var back := MatchConfig.from_dict(d)
	_check(back != null and var_to_str(back.to_dict()) == var_to_str(d), "MatchConfig to_dict/from_dict round-trips")
	var wire := MatchConfig.from_dict(bytes_to_var(var_to_bytes(d)))
	_check(wire != null and var_to_str(wire.to_dict()) == var_to_str(d), "round-trips through var_to_bytes")
	_check(back.coop.waves.size() == 2 and back.coop.waves[1].count == 4 and back.players[1].owner_peer == 2
			and back.players[0].display_name == "Host" and back.rng_seed == 1234567890123, "fields survive")
	_check(not var_to_str(d).contains("Resource") and not var_to_str(d).contains("Object"), "plain data only")
	var versus := MatchConfig.from_defaults(MatchConfig.Mode.LOCAL_VERSUS)
	var vb := MatchConfig.from_dict(versus.to_dict())
	_check(vb != null and vb.coop == null and var_to_str(vb.to_dict()) == var_to_str(versus.to_dict()), "versus config (no coop) round-trips")


func _test_config_garbage() -> void:
	var good := _full_config().to_dict()
	var cases: Array = [null, "x", 5, [], {"mode": "a"}, {"mode": 99}, {"players": "no"}, {"rng_seed": 1.5}]
	var mutations: Array[Callable] = [
		func(d: Dictionary) -> void: d["players"][0]["slot"] = "1",
		func(d: Dictionary) -> void: d["players"][0]["character_id"] = "nobody",
		func(d: Dictionary) -> void: d["players"][1]["slot"] = 0,
		func(d: Dictionary) -> void: d["players"][0]["input_kind"] = 7,
		func(d: Dictionary) -> void: d["players"][0]["slot"] = 1000,
		func(d: Dictionary) -> void: d["players"][0] = 3,
		func(d: Dictionary) -> void: d["coop"] = null,
		func(d: Dictionary) -> void: d["coop"]["waves"] = [1],
		func(d: Dictionary) -> void: d["coop"]["waves"][0]["character"] = "nobody",
		func(d: Dictionary) -> void: d["coop"]["endless"] = 1,
		func(d: Dictionary) -> void: d["players"][0]["display_name"] = 5,
		func(d: Dictionary) -> void:
			for i in MatchConfig.MAX_PLAYERS:
				d["players"].append({"slot": 10 + i}),
	]
	for m in mutations:
		var d: Dictionary = good.duplicate(true)
		m.call(d)
		cases.append(d)
	var rejected := 0
	for c: Variant in cases:
		if MatchConfig.from_dict(c) == null:
			rejected += 1
	_check(rejected == cases.size(), "garbage configs return null (%d/%d)" % [rejected, cases.size()])
	var clamp: Dictionary = good.duplicate(true)
	clamp["rounds_to_win"] = 100000
	clamp["round_time_seconds"] = -5
	clamp["players"][0]["cpu_level"] = 999
	clamp["players"][0]["display_name"] = "\u0007Bad\nName" + "x".repeat(100)
	clamp["coop"]["enemy_count"] = 100000
	var c := MatchConfig.from_dict(clamp)
	_check(c != null and c.rounds_to_win == MatchConfig.MAX_ROUNDS_TO_WIN and c.round_time_seconds == 0
			and c.players[0].cpu_level == Tuning.cpu.level_count() - 1 and c.coop.enemy_count == Tuning.coop.max_enemy_count,
			"out-of-range numbers are clamped")
	var nm := c.players[0].display_name if c != null else ""
	_check(nm.begins_with("BadName") and nm.length() == Tuning.net.name_max_len, "names are sanitized and trimmed (%s)" % nm)


func _test_player_tag_and_localize() -> void:
	var cfg := _full_config()
	_check(cfg.player_tag(0) == "Host" and cfg.player_tag(1) == "Guest" and cfg.player_tag(2) == "CPU", "online tags use profile names")
	for p in cfg.players:
		p.owner_peer = 0
	_check(cfg.player_tag(0) == "P1" and cfg.player_tag(2) == "CPU", "offline tags stay P1 / CPU")
	cfg = _full_config()
	cfg.localize_for_peer(2)
	var K := PlayerSlotConfig.InputKind
	_check(cfg.players[0].input_kind == K.NETWORK and cfg.players[1].input_kind == K.LOCAL and cfg.players[2].input_kind == K.CPU,
			"localize_for_peer: own slots LOCAL, others NETWORK, CPU stays")
	_check(cfg.local_view_slots() == [1] and cfg.layout() == MatchConfig.Layout.SINGLE_VIEW, "each machine views its own slots")
