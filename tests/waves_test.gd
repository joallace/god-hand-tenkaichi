extends Node
## Headless tests for co-op Waves (CoopRun, SPEC.md §6.2): wave order and
## per-wave counts / level / character overrides, the breather (no spawns,
## revives downed and out teammates, heal + ki), last wave clears the run,
## endless curve, wipe mid-run, save/load across a wave break. Run as a scene:
##   godot --headless res://tests/waves_test.tscn

var _failures := 0
var _started: Array = []  # wave indices
var _cleared: Array = []  # wave indices
var _run_end: Array = []  # cleared flags


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_wave_flow, _test_break_revives, _test_endless, _test_wipe,
		_test_save_load_break, _test_brawl_no_banners, _test_hud,
	]
	for t in tests:
		t.call()
	print("WAVES TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# --- harness ------------------------------------------------------------------

func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## Waves run: `humans` weakest-level CPU teammates; `waves` = per-wave
## WaveConfigs (empty + endless = the endless curve), in FIGHT.
func _new_run(humans: int, enemy_count: int, waves: Array[WaveConfig], endless := false,
		structure := CoopConfig.Structure.WAVES, hud: MatchHud = null) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_started.clear()
	_cleared.clear()
	_run_end.clear()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = 0
	cfg.rng_seed = 99
	cfg.coop = CoopConfig.new()
	cfg.coop.structure = structure
	cfg.coop.enemy_count = enemy_count
	cfg.coop.enemy_level = 0
	cfg.coop.waves = waves
	cfg.coop.endless = endless
	for i in humans:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 0
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.wave_started.connect(func(w: int) -> void: _started.append(w))
	d.wave_cleared.connect(func(w: int) -> void: _cleared.append(w))
	d.run_ended.connect(func(c: bool) -> void: _run_end.append(c))
	if hud != null:
		add_child(hud)
		hud.setup(d, null)
	d.setup(cfg)
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	return d


func _wave(count: int, level: int = -1, character: StringName = &"") -> WaveConfig:
	var w := WaveConfig.new()
	w.count = count
	w.level = level
	w.character = character
	return w


func _run(d: MatchDirector, n: int) -> void:
	for i in n:
		d.step()


func _team(d: MatchDirector, team: int) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in d.fighters:
		if f.team == team:
			out.append(f)
	return out


func _standing_enemies(d: MatchDirector) -> Array[Fighter]:
	return _team(d, CoopRun.ENEMY_TEAM).filter(func(f: Fighter) -> bool: return not f.is_ko())


func _ko(f: Fighter) -> void:
	f.health = 0.0
	f._enter_ko(Vector3.ZERO)


## KO every enemy of the current wave (spawning refills as they go) and step
## until the wave is cleared. False if it never clears.
func _clear_wave(d: MatchDirector) -> bool:
	var before := _cleared.size()
	for i in 4000:
		if _cleared.size() > before or d.coop.is_ended():
			return true
		for f in _standing_enemies(d):
			if f.state != Fighter.State.ENTERING:
				_ko(f)
		d.step()
	return false


func _brain_level(d: MatchDirector, f: Fighter) -> int:
	return (d.sources[d.fighters.find(f)] as CpuInput).brain.level


# --- tests --------------------------------------------------------------------

func _test_wave_flow() -> void:
	var lvl := Tuning.cpu.level_count() - 1
	var waves: Array[WaveConfig] = [_wave(2), _wave(3, lvl, &"brawler"), _wave(0)]
	var d := _new_run(1, 1, waves)
	_check(_started == [0], "wave 0 announced at run start")
	_check(d.coop.wave_total() == 3 and not d.coop.in_break(), "3 waves, not in a break")
	_check(d.coop.enemies_left() == 2, "wave 0 has its own count (2)")
	_check(_clear_wave(d), "wave 0 cleared")
	_check(_cleared == [0] and d.coop.in_break(), "wave_cleared(0) then a breather")
	_check(d.coop.waves_cleared() == 1 and _run_end.is_empty(), "1 wave cleared, run goes on")
	_run(d, Tuning.coop.wave_break_frames - 2)
	_check(_standing_enemies(d).is_empty() and _started == [0], "no enemies enter during the breather")
	_run(d, 2)
	_check(_started == [0, 1] and not d.coop.in_break(), "wave 1 starts after wave_break_frames")
	_check(d.coop.enemies_left() == 3, "wave 1 count override (3)")
	var e := _standing_enemies(d)
	var overrides_ok := e.size() == 3
	for f in e:
		overrides_ok = overrides_ok and _brain_level(d, f) == lvl and f.spawn_init["character_id"] == &"brawler"
	_check(overrides_ok, "wave 1 level / character overrides")
	_check(_clear_wave(d), "wave 1 cleared")
	_run(d, Tuning.coop.wave_break_frames)
	_check(d.coop.wave == 2 and d.coop.enemies_left() == 1, "wave 2 falls back to enemy_count (1)")
	_check(d.coop.is_last_wave(), "wave 2 is the last")
	_check(_clear_wave(d), "wave 2 cleared")
	_check(_run_end == [true] and d.coop.waves_cleared() == 3, "last wave clears the run")
	_check(d.phase == MatchDirector.Phase.MATCH_OVER, "run over")


func _test_break_revives() -> void:
	var waves: Array[WaveConfig] = [_wave(1), _wave(1)]
	var d := _new_run(3, 1, waves)
	var team := _team(d, CoopRun.HUMAN_TEAM)
	var downed := team[0]
	var out := team[1]
	var hurt := team[2]
	_ko(downed)
	_ko(out)
	_run(d, 2)
	out._enter(Fighter.State.OUT)
	hurt.health = hurt.tuning.max_health * 0.5
	hurt.ki = 0.0
	_check(downed.is_downed() and out.is_out(), "setup: one downed, one out")
	_check(_clear_wave(d), "wave 0 cleared")
	var t := Tuning.coop
	_check(not downed.is_ko() and not out.is_ko(), "the break revives downed and out teammates")
	_check(is_equal_approx(downed.health_ratio(), minf(t.revive_health_ratio + t.wave_heal_ratio, 1.0)),
			"revived at revive_health_ratio, plus the wave heal")
	_check(is_equal_approx(hurt.health_ratio(), minf(0.5 + t.wave_heal_ratio, 1.0)), "standing teammate healed")
	_check(hurt.ki >= minf(t.wave_ki_refill * Tuning.fighter.ki_bar_size, hurt.ki_max()) - 0.001,
			"ki refilled by wave_ki_refill bars")


func _test_endless() -> void:
	var t := Tuning.coop
	var d := _new_run(1, 1, [], true)
	_check(d.coop.wave_total() == -1 and not d.coop.is_last_wave(), "endless has no last wave")
	var ok_counts := true
	var ok_levels := true
	for i in 6:
		var want := mini(1 + floori(i * t.endless_count_growth), t.endless_max_count)
		ok_counts = ok_counts and d.coop.enemies_left() == want
		var want_level := Tuning.cpu.clamp_level(floori(i / float(t.endless_waves_per_level)))
		for f in _standing_enemies(d):
			ok_levels = ok_levels and _brain_level(d, f) == want_level
		if not _clear_wave(d):
			ok_counts = false
			break
		_run(d, t.wave_break_frames)
	_check(ok_counts, "endless counts follow enemy_count + n * growth")
	_check(ok_levels, "endless level rises every endless_waves_per_level waves")
	_check(_run_end.is_empty() and d.coop.waves_cleared() == 6, "endless never clears the run")


func _test_wipe() -> void:
	var waves: Array[WaveConfig] = [_wave(1), _wave(2)]
	var d := _new_run(1, 1, waves)
	_clear_wave(d)
	_run(d, Tuning.coop.wave_break_frames)
	_ko(_team(d, CoopRun.HUMAN_TEAM)[0])
	_run(d, 2)
	_check(_run_end == [false] and d.coop.waves_cleared() == 1, "wipe in wave 1 loses with 1 wave cleared")


func _test_save_load_break() -> void:
	var waves: Array[WaveConfig] = [_wave(2), _wave(3)]
	var d := _new_run(2, 1, waves)
	_clear_wave(d)
	_run(d, 20)
	var snap := d.save_state()
	_run(d, Tuning.coop.wave_break_frames + 30)  # through the next wave's entry
	var first := var_to_str(d.save_state())
	var started := _started.size()
	d.load_state(snap)
	_check(d.coop.in_break(), "load restores the breather")
	_run(d, Tuning.coop.wave_break_frames + 30)
	_check(first == var_to_str(d.save_state()), "re-simulating across the wave break is identical")
	_check(_started.size() == started + 1, "the next wave starts again after the load")


func _test_brawl_no_banners() -> void:
	var d := _new_run(1, 2, [], false, CoopConfig.Structure.BRAWL)
	_clear_wave(d)
	_check(_started.is_empty() and _cleared.is_empty(), "brawl: no wave signals")
	_check(_run_end == [true] and d.coop.wave_total() == 1, "brawl: one clear ends the run")


func _test_hud() -> void:
	var hud := MatchHud.new()
	var waves: Array[WaveConfig] = [_wave(1), _wave(1)]
	var d := _new_run(1, 1, waves, false, CoopConfig.Structure.WAVES, hud)
	var t := Tuning.hud
	_check(hud.wave_label != null and hud.wave_label.text == t.text_wave_counter % [1, 2], "HUD wave counter 1 / 2")
	_clear_wave(d)
	_check(hud.announcer.text == t.text_wave_clear, "WAVE CLEAR! announced on a break")
	_run(d, Tuning.coop.wave_break_frames)
	_check(hud.wave_label.text == t.text_wave_counter % [2, 2], "HUD wave counter 2 / 2")
	_check(hud.announcer.text == t.text_final_wave, "FINAL WAVE announced")
	_clear_wave(d)
	_check(hud.announcer.text == t.text_run_cleared, "the last clear announces the run result")
