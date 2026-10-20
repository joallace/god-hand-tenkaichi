extends Node
## Replays (SPEC_ONLINE.md §11): record matches, play them back headless and
## match the StateHash at every checkpoint and at the end; file format
## round-trip and rejection of bad files; version-mismatch warning; a human
## (scripted) slot with commands and a pause replays too; auto-keep rolling.
## Run as a scene:  godot --headless res://tests/replay_test.tscn

const Tool := preload("res://tools/replay_hash.gd")
const TMP_DIR := "user://test_replays/"
const VERSUS_TICKS := 1500
const COOP_TICKS := 2400
const SCRIPTED_TICKS := 900

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_versus_cpu, _test_coop_waves, _test_scripted_slot, _test_format_round_trip,
		_test_bad_files, _test_version_mismatch, _test_auto_keep,
	]
	for t in tests:
		t.call()
	_clean_tmp()
	print("REPLAY TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _verify(r: Replay, label: String) -> void:
	var res := ReplayPlayer.verify(r, self)
	_check(res["ok"] and res["checked"] >= r.hashes.size() - 1 and res["checked"] > 0,
			"%s: every checkpoint matches (%d checked, first mismatch %d)" % [label, res["checked"], res["first_mismatch"]])
	_check(res["final_hash"] == r.hashes.get(r.end_tick, -1), "%s: end hash matches at tick %d" % [label, r.end_tick])


func _test_versus_cpu() -> void:
	var r: Replay = Tool.record(self, Tool.cpu_config(false, 21, 4), VERSUS_TICKS)
	_check(r.end_tick == VERSUS_TICKS and r.inputs.is_empty(), "CPU vs CPU: recorded %d ticks, no human input stored" % r.end_tick)
	_check(r.hashes.size() >= VERSUS_TICKS / Tuning.net.replay_hash_interval, "hashes every replay_hash_interval ticks")
	_verify(r, "CPU vs CPU")
	# Played back from the file bytes too.
	_verify(Replay.from_bytes(r.to_bytes()), "CPU vs CPU from bytes")


func _test_coop_waves() -> void:
	var cfg: MatchConfig = Tool.cpu_config(true, 8, 0)
	cfg.round_time_seconds = 0
	for p in cfg.players:
		p.cpu_level = Tuning.cpu.level_count() - 1
	var waves: Array[int] = []
	var r: Replay = Tool.record(self, cfg, COOP_TICKS)
	_check(r.end_tick > 0 and r.match_config().coop.structure == CoopConfig.Structure.WAVES, "co-op Waves run recorded (%d ticks)" % r.end_tick)
	var d := ReplayPlayer.create_director(r, self)
	var enemies := [d.fighters.size() - cfg.players.size()]
	d.wave_started.connect(func(w: int) -> void: waves.append(w))
	d.entity_spawned.connect(func(e: SimEntity) -> void:
		if e is Fighter:
			enemies[0] += 1)
	while d.tick < r.end_tick:
		d.step()
	_check(enemies[0] > 0, "the run spawned enemies (%d, later waves started: %s)" % [enemies[0], waves])
	_check(StateHash.of(d) == r.hashes[r.end_tick], "co-op playback reaches the recorded end state")
	remove_child(d)
	d.queue_free()
	_verify(r, "co-op Waves")


## Slot 0 a human fed by TickInput (with PAUSE presses), taken over by a CPU
## and reclaimed mid-match, plus a pause / resume (RESYNC_INPUTS command).
func _test_scripted_slot() -> void:
	var cfg: MatchConfig = Tool.cpu_config(false, 33, 3)
	cfg.round_time_seconds = 0
	cfg.players[0].input_kind = PlayerSlotConfig.InputKind.LOCAL
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		return TickInput.new(5, 97) if p.input_kind != PlayerSlotConfig.InputKind.CPU else p.create_input_source()
	add_child(d)
	d.setup(cfg)
	var rec := ReplayRecorder.new()
	rec.auto_save = false
	add_child(rec)
	rec.attach(d)
	var pauses := [0]
	d.pause_requested.connect(func(_s: int) -> void: pauses[0] += 1)
	d.add_command({"tick": 300, "kind": MatchDirector.CommandKind.CPU_TAKEOVER, "slot": 0, "cpu_level": 2})
	d.add_command({"tick": 500, "kind": MatchDirector.CommandKind.RECLAIM, "slot": 0})
	while d.tick < SCRIPTED_TICKS:
		d.step()
		if d.tick == 600:
			d.paused = true
			d.paused = false
	var r := rec.finish()
	_check(pauses[0] > 0, "PAUSE presses reached pause_requested (%d)" % pauses[0])
	_check(r.inputs.has(0) and not r.inputs.has(1) and (r.inputs[0] as PackedByteArray).size() == SCRIPTED_TICKS * InputFrame.WIRE_SIZE,
			"human slot's frames recorded (6 bytes per tick), CPU slot not")
	_check(r.frame(0, 123).equals(TickInput.new(5).poll(123)), "recorded frame equals the source's frame")
	_check(r.commands.size() == 3 and r.commands[2]["kind"] == MatchDirector.CommandKind.RESYNC_INPUTS,
			"commands recorded (takeover, reclaim, resync on resume)")
	_verify(r, "scripted human slot")
	var tampered := Replay.from_dict(r.to_dict())
	var buf: PackedByteArray = tampered.inputs[0]
	var t := 700  # FIGHT, human in control again
	buf.encode_u16((t - 1) * InputFrame.WIRE_SIZE + 2, InputFrame.Btn.LIGHT)
	buf.encode_u16(t * InputFrame.WIRE_SIZE + 2, 0)
	tampered.inputs[0] = buf
	var res := ReplayPlayer.verify(tampered, self)
	_check(not res["ok"] and res["first_mismatch"] >= t, "a changed input frame is caught (first mismatch %d)" % res["first_mismatch"])
	remove_child(rec)
	rec.queue_free()


func _test_format_round_trip() -> void:
	var r: Replay = Tool.record(self, Tool.cpu_config(false, 2), 200)
	r.inputs[0] = PackedByteArray([1, 2, 3, 4, 0, 255])
	r.commands.append({"tick": 50, "kind": MatchDirector.CommandKind.FORFEIT, "team": 1, "winner": -1})
	var bytes := r.to_bytes()
	var back := Replay.from_bytes(bytes)
	_check(back != null and var_to_str(back.to_dict()) == var_to_str(r.to_dict()), "to_bytes/from_bytes round-trips")
	_check(bytes.slice(0, 4).get_string_from_ascii() == Replay.MAGIC, "file starts with the magic")
	var path := TMP_DIR.path_join("rt.ghr")
	_check(r.save(path) == OK, "save writes the file")
	var loaded := Replay.load_file(path)
	_check(loaded != null and var_to_str(loaded.to_dict()) == var_to_str(r.to_dict()), "load_file reads it back")
	var f := back.frame(0, 1) if back != null else InputFrame.new()
	_check(f.move_x == 1 and f.move_y == 2 and f.held == (3 | 4 << 8) and f.target_request == -1, "frames decode from the stored bytes")
	_check(back != null and back.frame(0, 2).equals(InputFrame.new()) and back.frame(3, 1).equals(InputFrame.new()),
			"missing ticks / slots read as neutral")


func _test_bad_files() -> void:
	var good := (Tool.record(self, Tool.cpu_config(false, 2), 60) as Replay).to_bytes()
	var bad_magic := good.duplicate()
	bad_magic[0] = 0
	var huge := good.duplicate()
	huge.encode_u32(4, 0x7FFFFFFF)
	var truncated := good.slice(0, good.size() / 2)
	var not_dict := Replay.MAGIC.to_ascii_buffer()
	var payload := var_to_bytes([1, 2, 3])
	not_dict.resize(Replay.HEADER_SIZE)
	not_dict.encode_u32(4, payload.size())
	not_dict.append_array(payload.compress(FileAccess.COMPRESSION_ZSTD))
	var cases := [PackedByteArray(), PackedByteArray([1, 2, 3]), bad_magic, huge, truncated, not_dict]
	var rejected := 0
	for b: PackedByteArray in cases:
		if Replay.from_bytes(b) == null:
			rejected += 1
	_check(rejected == cases.size(), "invalid files are rejected (%d/%d)" % [rejected, cases.size()])
	var d: Dictionary = Replay.from_bytes(good).to_dict()
	var mutations: Array[Callable] = [
		func(x: Dictionary) -> void: x["format_version"] = 999,
		func(x: Dictionary) -> void: x["inputs"] = {0: PackedByteArray([1, 2, 3])},
		func(x: Dictionary) -> void: x["inputs"] = {"0": PackedByteArray()},
		func(x: Dictionary) -> void: x["commands"] = [{"tick": "x"}],
		func(x: Dictionary) -> void: x["config"] = {"mode": 42},
		func(x: Dictionary) -> void: x["hashes"] = {1: "h"},
		func(x: Dictionary) -> void: x["end_tick"] = -1,
	]
	rejected = 0
	for m in mutations:
		var x := d.duplicate(true)
		m.call(x)
		if Replay.from_dict(x) == null:
			rejected += 1
	_check(rejected == mutations.size(), "malformed replay contents are rejected (%d/%d)" % [rejected, mutations.size()])
	_check(Replay.load_file(TMP_DIR.path_join("missing.ghr")) == null, "a missing file loads as null")


func _test_version_mismatch() -> void:
	var r: Replay = Tool.record(self, Tool.cpu_config(false, 4), 120)
	_check(r.version_mismatch() == "" and r.game_build == Replay.current_game_build(), "fresh recording matches this build")
	r.game_build = "0.0.1-other"
	r.engine_version += 1
	var back := Replay.from_bytes(r.to_bytes())
	_check(back != null, "a replay from another version still loads")
	var why := back.version_mismatch() if back != null else ""
	_check(why.begins_with("made with another version") and why.contains("engine") and why.contains("build"),
			"version mismatch reported (%s)" % why)
	r.engine_version -= 1
	r.game_build = Replay.current_game_build()
	r.content_hash = "deadbeef"
	_check(r.version_mismatch().contains("game data"), "content hash mismatch reported")
	_check(ContentHash.compute() == ContentHash.compute() and ContentHash.compute().length() == 64, "content hash is stable")
	var old := Tuning.coop.field_cap
	Tuning.coop.field_cap = old + 1
	var changed := ContentHash.compute()
	Tuning.coop.field_cap = old
	_check(changed != ContentHash.compute(), "content hash changes with a tuning value")


func _test_auto_keep() -> void:
	var dir := TMP_DIR.path_join("auto")
	var keep := Tuning.net.replay_keep_count
	Tuning.net.replay_keep_count = 2
	var r: Replay = Tool.record(self, Tool.cpu_config(false, 4), 30)
	for i in 3:
		r.end_tick = 10 + i
		r.save_auto(dir)
	Tuning.net.replay_keep_count = keep
	var newest := Replay.load_file(Replay.auto_path(1, dir))
	var older := Replay.load_file(Replay.auto_path(2, dir))
	_check(newest != null and newest.end_tick == 12 and older != null and older.end_tick == 11
			and not FileAccess.file_exists(Replay.auto_path(3, dir)), "auto-keep rolls over replay_keep_count, newest first")
	var copy := r.save_copy("", TMP_DIR.path_join("saved"))
	_check(copy.ends_with("_versus_cpu.ghr") and Replay.load_file(copy) != null, "save_copy writes <date>_<mode>.ghr (%s)" % copy.get_file())
	var rec := ReplayRecorder.new()
	_check(not rec._auto_enabled(), "headless runs don't auto-keep by default")
	rec.free()


func _clean_tmp() -> void:
	_remove_dir(ProjectSettings.globalize_path(TMP_DIR))


func _remove_dir(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(sub))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
