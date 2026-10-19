extends Node
## RunStats (co-op results counters) and the co-op results screen. Run as a
## scene:  godot --headless res://tests/run_stats_test.tscn
##   1. scripted fighter events on real fighters -> KO attribution, damage,
##      best combo, revives given, perfect dodges
##   2. a short real CPU run -> KOs add up, run time = FIGHT ticks
##   3. the results screen builds from the stats and fits the base viewport

const RUN_ENEMIES := 3
## Sim ticks before giving up on the real run ending.
const MAX_TICKS := 21600
## Base viewport (project.godot display/window/size).
const BASE_VIEWPORT := Vector2(1152, 648)

var _failures := 0


func _ready() -> void:
	_test_scripted_events()
	var res := _test_real_run()
	await _test_results_screen(res)
	_test_team_text()
	print("RUN STATS TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _config(players: int, enemies: int) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = 0
	cfg.rng_seed = 4321
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = enemies
	cfg.coop.enemy_level = 0
	for i in players:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = Tuning.cpu.level_names.size() - 1
		cfg.players.append(p)
	return cfg


## Director + hub + RunStats wired like MatchScene does.
func _new_run(cfg: MatchConfig) -> Array:
	for c in get_children():
		c.queue_free()
	var hub := MatchEventHub.new()
	add_child(hub)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	var rs := RunStats.new()
	add_child(rs)
	rs.setup(d, hub, cfg)
	d.fighters_spawned.connect(func(fs: Array[Fighter]) -> void: hub.watch(fs))
	d.entity_spawned.connect(func(e: SimEntity) -> void:
		if e is Fighter:
			hub.watch_fighter(e as Fighter))
	d.setup(cfg)
	return [d, rs]


func _enemy(d: MatchDirector) -> Fighter:
	for f in d.fighters:
		if f.team != CoopRun.HUMAN_TEAM:
			return f
	return null


## Victim-side hit event (positions differ so the hub never dedups them).
func _hit(victim: Fighter, attacker: int, dmg: float, combo: int, n: int, blocked := false) -> void:
	victim.event.emit(&"hit", {
		"slot": victim.slot, "attacker_slot": attacker, "damage": dmg,
		"position": Vector3(n, 0, 0), "heavy": false, "blocked": blocked,
		"combo": combo, "guard_result": -1,
	})


func _test_scripted_events() -> void:
	var cfg := _config(2, 2)
	var parts := _new_run(cfg)
	var d: MatchDirector = parts[0]
	var rs: RunStats = parts[1]
	while (_enemy(d) == null or d.phase != MatchDirector.Phase.FIGHT) and d.tick < MAX_TICKS:
		d.step()
	d.step()
	var e := _enemy(d)
	if not _check(e != null, "an enemy spawned"):
		return
	var p0 := d.fighter_for_slot(0)
	var p1 := d.fighter_for_slot(1)
	_hit(e, 0, 10.0, 1, 1)
	_hit(e, 1, 5.0, 3, 2)
	_hit(e, 0, 2.0, 9, 3, true)  # blocked: chip counts, combo doesn't
	e.event.emit(&"ko", {"slot": e.slot, "position": Vector3.ZERO})
	_hit(e, 1, 7.0, 4, 4)  # the KO hit (emitted after &"ko")
	_hit(p0, e.slot, 30.0, 2, 5)  # enemy hitting a player: not "dealt"
	_hit(p1, 0, 3.0, 6, 6)  # friendly fire: not counted
	p0.event.emit(&"perfect_dodge", {"slot": 0, "attacker_slot": e.slot, "dodge": &"left", "position": Vector3.ZERO})
	p0.event.emit(&"perfect_dodge", {"slot": 0, "attacker_slot": e.slot, "dodge": &"back", "position": Vector3.ZERO})
	p1.event.emit(&"perfect_dodge", {"slot": 1, "attacker_slot": e.slot, "dodge": &"left", "position": Vector3.ZERO})
	p1.event.emit(&"revived", {"slot": 1, "reviver_slot": 0})
	p0.event.emit(&"revived", {"slot": 0, "reviver_slot": -1})  # revive_now: nobody
	# A KO with no attributed hit after it goes to the victim's last attacker.
	_hit(e, 0, 1.0, 2, 7)
	e.event.emit(&"ko", {"slot": e.slot, "position": Vector3.ZERO})

	var r := rs.result()
	var s0: Dictionary = r["stats"][0]
	var s1: Dictionary = r["stats"][1]
	_check(s1[RunStats.KOS] == 1, "KO credited to the attacker of the KO hit (%s)" % s1)
	_check(s0[RunStats.KOS] == 1, "unattributed KO falls back to the last attacker (%s)" % s0)
	_check(is_equal_approx(s0[RunStats.DAMAGE], 13.0), "P1 damage = hits + chip on enemies (%s)" % s0[RunStats.DAMAGE])
	_check(is_equal_approx(s1[RunStats.DAMAGE], 12.0), "P2 damage (%s)" % s1[RunStats.DAMAGE])
	_check(s0[RunStats.BEST_COMBO] == 2 and s1[RunStats.BEST_COMBO] == 4,
			"best combo ignores blocked hits / friendly fire (%d, %d)" % [s0[RunStats.BEST_COMBO], s1[RunStats.BEST_COMBO]])
	_check(s0[RunStats.REVIVES] == 1 and s1[RunStats.REVIVES] == 0, "revives given")
	_check(s0[RunStats.PERFECT_DODGES] == 2 and s1[RunStats.PERFECT_DODGES] == 1, "perfect dodges")
	_check(not r["stats"].has(e.slot), "enemies get no stats record")
	_check(int(r["run"]["waves_cleared"]) == -1, "no waves count in a Brawl run")
	_check(int(r["run"]["frames"]) > 0, "run time counts FIGHT ticks so far")


func _test_real_run() -> Dictionary:
	var cfg := _config(2, RUN_ENEMIES)
	var parts := _new_run(cfg)
	var d: MatchDirector = parts[0]
	var rs: RunStats = parts[1]
	var ended := []
	d.run_ended.connect(func(c: bool) -> void: ended.append(c))
	var fight_ticks := 0
	while ended.is_empty() and d.tick < MAX_TICKS:
		var in_fight := d.phase == MatchDirector.Phase.FIGHT
		d.step()
		if in_fight:
			fight_ticks += 1
	_check(not ended.is_empty(), "real run ends (cleared %s, tick %d)" % [ended, d.tick])
	var r := rs.result()
	print("  run %s stats %s" % [r["run"], r["stats"]])
	_check(bool(r["run"]["cleared"]) == (ended == [true]), "run cleared flag matches run_ended")
	_check(int(r["run"]["frames"]) == fight_ticks, "run frames = FIGHT ticks (%d vs %d)" % [r["run"]["frames"], fight_ticks])
	var kos := 0
	var dmg := 0.0
	for slot: int in r["stats"]:
		kos += int(r["stats"][slot][RunStats.KOS])
		dmg += float(r["stats"][slot][RunStats.DAMAGE])
	if ended == [true]:
		_check(kos == RUN_ENEMIES, "every enemy KO credited to a player (%d)" % kos)
	_check(dmg > 0.0, "players dealt damage (%.0f)" % dmg)
	var out := {"winner_slot": 0 if ended == [true] else -1, "wins": d.wins, "config": cfg}
	out.merge(r)
	return out


func _test_results_screen(res: Dictionary) -> void:
	# Three team-0 players (two humans + CPU ally) is the widest table.
	var cfg := res["config"] as MatchConfig
	var ally := PlayerSlotConfig.new()
	ally.slot = cfg.players.size()
	ally.input_kind = PlayerSlotConfig.InputKind.CPU
	cfg.players[0].input_kind = PlayerSlotConfig.InputKind.LOCAL
	cfg.players[1].input_kind = PlayerSlotConfig.InputKind.LOCAL
	cfg.players.append(ally)
	cfg.coop.structure = CoopConfig.Structure.WAVES
	cfg.coop.waves = [WaveConfig.new(), WaveConfig.new()] as Array[WaveConfig]
	res["run"]["waves_cleared"] = 1
	for c in get_children():
		c.queue_free()
	Game.last_result = res
	var r := (load(Game.SCENE_RESULTS) as PackedScene).instantiate() as ResultsScreen
	add_child(r)
	for i in 4:
		await get_tree().process_frame
	_check(r._table != null and r._table.columns == 4, "co-op results: stats table with a column per player")
	_check(r._table.get_child_count() == 4 * (2 + RunStats.ROWS.size()), "table has tag, character and stat rows")
	var tags: PackedStringArray = []
	for i in range(1, 4):
		tags.append((r._table.get_child(i) as Label).text)
	_check(tags == PackedStringArray(["P1", "P2", "CPU"]), "column tags %s" % tags)
	_check(r._tally.text.contains("Waves cleared: 1 / 2") and r._tally.text.contains("Time "),
			"team line shows waves and time (%s)" % r._tally.text)
	var need := r._col.get_combined_minimum_size()
	_check(need.x <= BASE_VIEWPORT.x and need.y <= BASE_VIEWPORT.y,
			"results column fits the base viewport %s (needs %s)" % [BASE_VIEWPORT, need])
	_check(r._table_scroll.size.y >= r._table.size.y, "3-player table needs no scrolling")
	_check(get_viewport().gui_get_focus_owner() == r._rematch_btn and r._rematch_btn.text == "Retry",
			"Retry focused")
	r.queue_free()
	Game.last_result = {}
	await get_tree().process_frame


func _test_team_text() -> void:
	var cfg := _config(1, 4)
	var res := {"config": cfg, "run": {"cleared": true, "seconds": 83.6, "waves_cleared": -1}}
	var t := ResultsScreen.coop_team_text(res)
	_check(t.contains("Brawl: 4 enemies") and t.contains("1:23") and not t.contains("Waves"),
			"brawl team line (%s)" % t)
	_check(ResultsScreen.coop_cleared({"config": cfg, "winner_slot": -1, "run": {"cleared": true}}),
			"run.cleared marks the run cleared")
	cfg.coop.structure = CoopConfig.Structure.WAVES
	cfg.coop.endless = true
	res["run"]["waves_cleared"] = 7
	_check(ResultsScreen.coop_team_text(res).contains("Waves cleared: 7"), "endless waves line")
	_check(ResultsScreen.stat_text({0: {RunStats.DAMAGE: 12.6}}, 0, RunStats.DAMAGE) == "13", "damage rounds")
	_check(ResultsScreen.stat_text({}, 0, RunStats.KOS) == "-", "missing stats show a dash")
