extends Node
## Headless CPU test: a scripted player loops one attack pattern (jab, wait,
## jab; three-hit strings, wait, again) against CPUs of several levels. The
## CPU must not get stuck eating it: out of hitstun it guards first (the
## attacker is the one at frame advantage) and it learns the habit and
## counters it. Weak levels may still fall for it.
##   godot --headless res://tests/cpu_pattern_test.tscn             (asserts)
##   godot --headless res://tests/cpu_pattern_test.tscn -- sweep    (table)
##
## "trap" = longest run of fresh combos (first hit of a combo) the CPU takes
## from the pattern with no answer in between (block, dodge, vanish, counter
## guard, or a clean hit of its own).

const TICKS := 1800
const SEEDS := 3
## [burst, gap]: LIGHT presses per cycle, frames from its last press to the next cycle.
const PATTERNS: Array = [[1, 16], [1, 26], [3, 20], [3, 30]]

var _failures := 0
var _events: Array = []


func _ready() -> void:
	if "sweep" in OS.get_cmdline_user_args():
		_sweep()
		get_tree().quit(0)
		return
	var top := Tuning.cpu.level_count() - 1
	var mid := Tuning.cpu.default_level
	for p in PATTERNS:
		var label := "burst %d gap %d" % p
		var weak := _run_pattern(0, p[0], p[1])
		var normal := _run_pattern(mid, p[0], p[1])
		var strong := _run_pattern(top, p[0], p[1])
		print("  [%s] weak %s | mid %s | top %s" % [label, weak, normal, strong])
		_check(normal["trap"] <= 6, "%s: level %d escapes the loop (trap %d <= 6)" % [label, mid, normal["trap"]])
		_check(strong["trap"] <= 3, "%s: top level shuts it down (trap %d <= 3)" % [label, strong["trap"]])
		_check(strong["hits"] < weak["hits"] * 0.8,
				"%s: top level takes far fewer hits than the weakest (%d vs %d)" % [label, strong["hits"], weak["hits"]])
		_check(strong["counters"] + strong["cpu_hits"] > 0,
				"%s: top level hits back (%d counters, %d clean hits)" % [label, strong["counters"], strong["cpu_hits"]])
		_check(weak["trap"] >= 4, "%s: the weakest level still falls for it (trap %d >= 4)" % [label, weak["trap"]])
	_test_learns()
	_test_save_load()
	print("CPU PATTERN TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


## The top CPU notices the jab loop: its habit heat passes the read
## threshold and it learns the re-press delay.
func _test_learns() -> void:
	var top := Tuning.cpu.level_count() - 1
	var d := _new_match(top, 7, PatternInput.new(1, 26))
	_steps(d, 900)
	var brain := (d.sources[1] as CpuInput).brain
	_check(brain._habit_move == &"brawler_jab1" and brain._habit_bias() >= Tuning.cpu.habit_read_heat
			and brain._habit_delay >= 0,
			"top CPU learns the jab habit (move %s, bias %.2f, delay %d)" % [brain._habit_move, brain._habit_bias(), brain._habit_delay])


## Habit memory round-trips with the rest of the brain mid-pattern.
func _test_save_load() -> void:
	var d := _new_match(Tuning.cpu.level_count() - 1, 9, PatternInput.new(3, 20))
	_steps(d, 700)
	var cpu := d.sources[1] as CpuInput
	var snap := cpu.save_state()
	var a: Array[InputFrame] = []
	for i in 30:
		a.append(cpu.brain.think())
	var after_a := var_to_str(cpu.brain.save_state())
	cpu.load_state(snap)
	var same := true
	for i in 30:
		same = same and a[i].equals(cpu.brain.think())
	_check(same and after_a == var_to_str(cpu.brain.save_state()) and snap["brain"]["_habit_heat"] > 0.0,
			"CPU habit memory round-trips save/load (heat %.2f)" % snap["brain"]["_habit_heat"])


func _sweep() -> void:
	var levels := [0, 3, 5, Tuning.cpu.level_count() - 1]
	var configs: Array = []
	for gap in [14, 16, 18, 20, 22, 24, 26, 28, 32, 40]:
		configs.append([1, gap])
	for gap in [16, 20, 24, 30, 40]:
		configs.append([3, gap])
	for c in configs:
		var line := "burst %d gap %2d:" % c
		for lvl in levels:
			var r := _run_pattern(lvl, c[0], c[1])
			line += " L%d hit %3d late %3d trap %2d blk %3d cpu %3d ctr %2d |" % [lvl, r["hits"], r["late"],
				r["trap"], r["blocks"], r["cpu_hits"], r["counters"]]
		print(line)


# --- harness ------------------------------------------------------------------

## Versus match in FIGHT, player (slot 0) on `src`, CPU (slot 1) at `lvl`,
## standing in jab range.
func _new_match(lvl: int, seed_value: int, src: InputSource) -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 0
	cfg.rng_seed = seed_value
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = lvl
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	d.sources[0] = src
	src.attach(d, 0)
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in 2:
		var pos := Vector3(0, 0, 0.8 if i == 0 else -0.8)
		d.fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		d.fighters[i].event.connect(func(kind: StringName, data: Dictionary) -> void:
			_events.append([i, kind, data]))
	return d


## Step with health refilled every tick (the loop never ends in a KO).
func _steps(d: MatchDirector, n: int) -> void:
	for t in n:
		for f in d.fighters:
			f.health = f.tuning.max_health
		d.step()


## Totals over SEEDS matches of TICKS: clean hits the CPU took (and in the
## second half), longest trap, blocks, its clean hits, counters (perfect
## dodges, counter guards, vanishes).
func _run_pattern(lvl: int, burst: int, gap: int) -> Dictionary:
	var r := {"hits": 0, "late": 0, "trap": 0, "blocks": 0, "cpu_hits": 0, "counters": 0}
	for s in SEEDS:
		var d := _new_match(lvl, 100 + s, PatternInput.new(burst, gap))
		var run := 0
		var seen := 0
		for t in TICKS:
			_steps(d, 1)
			while seen < _events.size():
				var e: Array = _events[seen]
				seen += 1
				var kind: StringName = e[1]
				var data: Dictionary = e[2]
				if kind == &"hit" and e[0] == 1 and not data["blocked"]:
					r["hits"] += 1
					if t >= TICKS / 2:
						r["late"] += 1
					if data["combo"] == 1:
						run += 1
						r["trap"] = maxi(r["trap"], run)
				elif kind == &"hit" and e[0] == 1:
					r["blocks"] += 1
					run = 0
				elif kind == &"hit" and e[0] == 0 and not data["blocked"]:
					r["cpu_hits"] += 1
					run = 0
				elif e[0] == 1 and kind in [&"perfect_dodge", &"counter_guard", &"vanish"]:
					r["counters"] += 1
					run = 0
				elif e[0] == 1 and kind == &"dodge":
					run = 0
	return r
