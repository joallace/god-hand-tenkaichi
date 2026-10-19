class_name ReplayPlayer
extends RefCounted
## Re-simulates a Replay headless and checks its hashes. Human slots read
## their recorded frames (ReplayInput through MatchDirector.source_factory);
## CPU slots keep CpuInput, so playback also verifies CPU determinism (the
## brains' state is in the hash). Recorded commands are re-logged.


## A director (child of `parent`, auto_step off, set up at tick 0) ready to
## replay `replay`, or null when its config doesn't validate.
static func create_director(replay: Replay, parent: Node) -> MatchDirector:
	var cfg := replay.match_config()
	if cfg == null:
		return null
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			return p.create_input_source()
		return ReplayInput.new(replay.inputs.get(p.slot, PackedByteArray()))
	parent.add_child(d)
	d.setup(cfg)
	for c in replay.commands:
		d.add_command(c)
	return d


## Play `replay` to its end_tick under `parent`, comparing every recorded
## hash. on_checkpoint(tick, recorded, actual) is called per checkpoint.
## Returns {"ok": bool, "checked": int, "mismatches": int,
## "first_mismatch": tick or -1, "end_tick": int, "final_hash": int}.
## The director is freed afterwards.
static func verify(replay: Replay, parent: Node, on_checkpoint: Callable = Callable()) -> Dictionary:
	var out := {"ok": false, "checked": 0, "mismatches": 0, "first_mismatch": -1, "end_tick": replay.end_tick, "final_hash": 0}
	var d := create_director(replay, parent)
	if d == null:
		return out
	while d.tick < replay.end_tick:
		d.step()
		if replay.hashes.has(d.tick):
			var actual := StateHash.of(d)
			var recorded: int = replay.hashes[d.tick]
			out["checked"] += 1
			if actual != recorded:
				out["mismatches"] += 1
				if out["first_mismatch"] < 0:
					out["first_mismatch"] = d.tick
			if on_checkpoint.is_valid():
				on_checkpoint.call(d.tick, recorded, actual)
	out["final_hash"] = StateHash.of(d)
	out["ok"] = out["mismatches"] == 0
	parent.remove_child(d)
	d.queue_free()
	return out
