extends Node
## Replay hash stream (SPEC_ONLINE.md §6 rule 5): plays a replay back
## headless and prints one `<tick> <hash>` line per recorded checkpoint, then
## `end <tick> <hash> OK|MISMATCH (<n> of <m> checkpoints differ)`. Exits 1
## if any recorded hash differs (or the file is invalid). Run the same file
## on Linux and Windows to check cross-OS determinism.
##   godot --headless res://tools/replay_hash.tscn -- replay=<path>
## Record a CPU-only match first (no human input needed):
##   godot --headless res://tools/replay_hash.tscn -- record=<path> [seed=1 mode=versus|coop ticks=3600 level=<cpu level>]

const DEFAULTS := {"replay": "", "record": "", "seed": "1", "mode": "versus", "ticks": "3600", "level": "-1"}

## CPU-only co-op Waves setup used by `record` (and replay_test).
const COOP_WAVES := 3
const COOP_WAVE_ENEMIES := 2
const COOP_HUMANS := 2


func _ready() -> void:
	var args := DEFAULTS.duplicate()
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and args.has(kv[0]):
			args[kv[0]] = kv[1]
	var code := 0
	if args["record"] != "":
		code = _record(args)
	elif args["replay"] != "":
		code = _play(args["replay"])
	else:
		printerr("usage: -- replay=<path> | record=<path> [seed=<n> mode=versus|coop ticks=<n> level=<n>]")
		code = 2
	get_tree().quit(code)


func _record(args: Dictionary) -> int:
	var cfg := cpu_config(args["mode"] == "coop", int(args["seed"]), int(args["level"]))
	var r := record(self, cfg, int(args["ticks"]))
	var path: String = args["record"]
	if r.save(path) != OK:
		printerr("could not write %s" % path)
		return 1
	print("recorded %s: %d ticks, %d checkpoints, end hash %d" % [path, r.end_tick, r.hashes.size(), r.hashes.get(r.end_tick, 0)])
	return 0


func _play(path: String) -> int:
	var r := Replay.load_file(path)
	if r == null:
		printerr("not a valid replay: %s" % path)
		return 1
	var why := r.version_mismatch()
	if why != "":
		print("warning: %s" % why)
	var res := ReplayPlayer.verify(r, self, func(t: int, recorded: int, actual: int) -> void:
		print("%d %d%s" % [t, actual, "" if actual == recorded else "  MISMATCH (recorded %d)" % recorded]))
	print("end %d %d %s (%d of %d checkpoints differ)" % [res["end_tick"], res["final_hash"],
		"OK" if res["ok"] else "MISMATCH", res["mismatches"], res["checked"]])
	return 0 if res["ok"] else 1


## Every slot a CPU. Versus: 1v1. Co-op: COOP_HUMANS CPU "humans" in a Waves
## run of COOP_WAVES waves. level -1 = Tuning.cpu.default_level.
static func cpu_config(coop: bool, seed_value: int, level: int = -1) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP if coop else MatchConfig.Mode.VERSUS_CPU)
	cfg.rng_seed = seed_value
	if coop:
		cfg.coop = CoopConfig.new()
		cfg.coop.structure = CoopConfig.Structure.WAVES
		cfg.coop.enemy_level = level
		for i in COOP_WAVES:
			var w := WaveConfig.new()
			w.count = COOP_WAVE_ENEMIES
			cfg.coop.waves.append(w)
	for i in (COOP_HUMANS if coop else 2):
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = level
		cfg.players.append(p)
	return cfg


## Run `cfg` headless for `ticks` ticks (or until the match is over) under
## `parent` and return the finished recording. The director is freed.
static func record(parent: Node, cfg: MatchConfig, ticks: int) -> Replay:
	var d := MatchDirector.new()
	d.auto_step = false
	parent.add_child(d)
	d.setup(cfg)
	var rec := ReplayRecorder.new()
	rec.auto_save = false
	parent.add_child(rec)
	rec.attach(d)
	while d.tick < ticks and d.phase != MatchDirector.Phase.MATCH_OVER:
		d.step()
	var r := rec.finish()
	parent.remove_child(rec)
	rec.queue_free()
	parent.remove_child(d)
	d.queue_free()
	return r
