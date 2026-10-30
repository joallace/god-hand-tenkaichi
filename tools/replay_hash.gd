extends Node
## Replay hash stream (SPEC_ONLINE.md §6 rule 5): plays a replay back
## headless and prints one `<tick> <hash>` line per recorded checkpoint, then
## `end <tick> <hash> OK|MISMATCH (<n> of <m> checkpoints differ)`. Exits 1
## if any recorded hash differs (or the file is invalid). Run the same file
## on Linux and Windows to check cross-OS determinism.
##   godot --headless res://tools/replay_hash.tscn -- replay=<path>
## Record a CPU-only match first (no human input needed):
##   godot --headless res://tools/replay_hash.tscn -- record=<path> [seed=1 mode=versus|coop ticks=3600 level=<cpu level>]
## `humans=<n>` CPU fighters (versus: free-for-all above 2; co-op: team 0),
## `enemies=<n>` (co-op: a Brawl of n enemies instead of the Waves setup, so
## the field stays at Tuning.coop.field_cap), `enemy_level=<n>` (co-op
## enemies; default = level).
## Dump the full state at a tick (var_to_str of save_state) to diff two
## platforms or peers:
##   godot --headless res://tools/replay_hash.tscn -- replay=<path> dump=<tick> out=<file>
## `replay=all` plays every .ghr in BUNDLED_DIR (the "Web Tools" export
## bundles them: tools/web_tools.sh tool=replay, cross-runtime check).

const DEFAULTS := {"replay": "", "record": "", "seed": "1", "mode": "versus", "ticks": "3600", "level": "-1",
	"dump": "", "out": "", "humans": "0", "enemies": "0", "enemy_level": ""}
## Replays recorded on desktop for the browser determinism check.
const BUNDLED_DIR := "res://tools/replays/"

## CPU-only co-op Waves setup used by `record` (and replay_test).
const COOP_WAVES := 3
const COOP_WAVE_ENEMIES := 2
const COOP_HUMANS := 2


func _ready() -> void:
	var args := DEFAULTS.duplicate()
	for a in ToolArgs.pairs():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and args.has(kv[0]):
			args[kv[0]] = kv[1]
	if OS.has_feature("web_tools") and args["replay"] == "" and args["record"] == "":
		args["replay"] = "all"
	var code := 0
	if args["record"] != "":
		code = _record(args)
	elif args["replay"] == "all":
		code = await _play_bundled()
	elif args["replay"] != "" and args["dump"] != "":
		code = _dump(args["replay"], int(args["dump"]), args["out"])
	elif args["replay"] != "":
		code = _play(args["replay"])
	else:
		printerr("usage: -- replay=<path> | record=<path> [seed=<n> mode=versus|coop ticks=<n> level=<n>]")
		code = 2
	get_tree().quit(code)


func _record(args: Dictionary) -> int:
	var cfg := cpu_config(args["mode"] == "coop", int(args["seed"]), int(args["level"]),
		int(args["humans"]), int(args["enemies"]))
	if cfg.coop != null and args["enemy_level"] != "":
		cfg.coop.enemy_level = int(args["enemy_level"])
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


## Every bundled replay, one REPLAY_HASH line per checkpoint (`<file> <tick>
## <hash>`), a per-file verdict, then `REPLAY_HASH DONE OK|MISMATCH`. Yields
## a frame between files so a browser page keeps flushing its console.
func _play_bundled() -> int:
	var files: Array[String] = []
	for f in DirAccess.get_files_at(BUNDLED_DIR):
		if f.ends_with(".ghr"):
			files.append(f)
	files.sort()
	print("REPLAY_HASH start %s content %s, %d replays" % [OS.get_name(), ContentHash.compute(), files.size()])
	var all_ok := not files.is_empty()
	for f in files:
		await get_tree().process_frame
		var r := Replay.load_file(BUNDLED_DIR + f)
		if r == null:
			print("REPLAY_HASH %s INVALID" % f)
			all_ok = false
			continue
		var why := r.version_mismatch()
		if why != "":
			print("REPLAY_HASH %s warning: %s" % [f, why])
		var t0 := Time.get_ticks_msec()
		var res := ReplayPlayer.verify(r, self, func(t: int, recorded: int, actual: int) -> void:
			print("REPLAY_HASH %s %d %d%s" % [f, t, actual, "" if actual == recorded else "  MISMATCH (recorded %d)" % recorded]))
		print("REPLAY_HASH %s end %d %d %s (%d of %d checkpoints differ, %d ms)" % [f, res["end_tick"], res["final_hash"],
			"OK" if res["ok"] else "MISMATCH", res["mismatches"], res["checked"], Time.get_ticks_msec() - t0])
		all_ok = all_ok and res["ok"]
	print("REPLAY_HASH DONE %s" % ("OK" if all_ok else "MISMATCH"))
	return 0 if all_ok else 1


func _dump(path: String, at_tick: int, out: String) -> int:
	var r := Replay.load_file(path)
	var d := ReplayPlayer.create_director(r, self) if r != null else null
	if d == null:
		printerr("not a valid replay: %s" % path)
		return 1
	while d.tick < at_tick:
		d.step()
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("could not write %s" % out)
		return 1
	f.store_string(var_to_str(d.save_state()))
	print("dumped tick %d hash %d to %s" % [d.tick, StateHash.of(d), out])
	return 0


## Every slot a CPU. Versus: 1v1. Co-op: COOP_HUMANS CPU "humans" in a Waves
## run of COOP_WAVES waves. level -1 = Tuning.cpu.default_level.
## humans > 0 overrides the fighter count (versus) / team-0 count (co-op);
## enemies > 0 makes the co-op run a Brawl of that many enemies.
static func cpu_config(coop: bool, seed_value: int, level: int = -1, humans: int = 0, enemies: int = 0) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP if coop else MatchConfig.Mode.VERSUS_CPU)
	cfg.rng_seed = seed_value
	if coop:
		cfg.coop = CoopConfig.new()
		cfg.coop.enemy_level = level
		if enemies > 0:
			cfg.coop.structure = CoopConfig.Structure.BRAWL
			cfg.coop.enemy_count = enemies
		else:
			cfg.coop.structure = CoopConfig.Structure.WAVES
			for i in COOP_WAVES:
				var w := WaveConfig.new()
				w.count = COOP_WAVE_ENEMIES
				cfg.coop.waves.append(w)
	var n := humans if humans > 0 else (COOP_HUMANS if coop else 2)
	var ids := CharacterRegistry.IDS
	for i in n:
		var p := PlayerSlotConfig.new()
		p.slot = i
		if humans > 0:
			p.character_id = ids[i % ids.size()]
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = level
		cfg.players.append(p)
	return cfg


## Run `cfg` headless for `ticks` ticks (or until the match is over) under
## `parent` and return the finished recording. The director is freed.
## The config goes through to_dict/from_dict first (as online and replay
## playback do), so clamped values are recorded as the sim really ran them.
static func record(parent: Node, cfg: MatchConfig, ticks: int) -> Replay:
	cfg = MatchConfig.from_dict(cfg.to_dict())
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
