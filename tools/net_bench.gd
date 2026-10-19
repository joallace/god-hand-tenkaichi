extends Node
## Headless rollback cost bench (SPEC_ONLINE.md §12): builds a CPU-only match,
## warms it up into the fight, then times step(), save_state(), load_state(),
## snapshot serialization (var_to_bytes + hash, the desync-check cost) and an
## N-tick rollback (load an N-tick-old snapshot, re-step N ticks), and checks
## that the re-simulated state matches the straight run byte for byte.
## A scene, not --script, so autoloads exist:
##   godot --headless res://tools/net_bench.tscn [-- mode=coop humans=2 enemies=4
##       ticks=1800 warmup=600 rollback=8 seed=7 level=7 enemy_level=3]
## mode=coop: `humans` CPU stand-ins on team 0, `enemies` on the field (the
## queue is kept deep so the field stays full); Tuning.coop.field_cap still
## applies, so pass coop.field_cap=<n> to bench a bigger field. Any
## `coop.<property>=<number>` overrides that Tuning.coop value.
## mode=versus: `humans` CPU fighters, 1v1 or free-for-all.
## rollback defaults to Tuning.net.max_rollback_frames. The match restarts from
## the warmup snapshot whenever it leaves the FIGHT phase.

## Per-frame budget for rollback work (ms): half a 60 Hz frame (§12).
const BUDGET_MS := 8.0
## Brawl queue = enemies × this, so KO'd enemies keep being replaced.
const QUEUE_FACTOR := 1000

var _args := {"mode": "coop", "humans": 2, "enemies": 4, "ticks": 1800, "warmup": 600,
	"rollback": -1, "seed": 7, "level": 7, "enemy_level": 3}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "mode":
			_args["mode"] = kv[1]
		elif _args.has(kv[0]):
			_args[kv[0]] = int(kv[1])
		elif kv[0].begins_with("coop."):
			var prop := kv[0].trim_prefix("coop.")
			var cur: Variant = Tuning.coop.get(prop)
			Tuning.coop.set(prop, float(kv[1]) if cur is float else int(kv[1]))
			print("override coop.%s = %s" % [prop, Tuning.coop.get(prop)])
	if _args["mode"] == "coop":
		# Field = humans + enemies, never above the (possibly overridden) cap.
		var cap := mini(Tuning.coop.field_cap, _args["humans"] + _args["enemies"])
		if cap < _args["humans"] + _args["enemies"]:
			print("field_cap %d < humans + enemies: only %d enemies on the field" % [cap, cap - _args["humans"]])
		Tuning.coop.field_cap = cap
	if _args["rollback"] < 0:
		_args["rollback"] = Tuning.net.max_rollback_frames
	print("net_bench ", _args)
	var ok := _bench()
	get_tree().quit(0 if ok else 1)


func _config() -> MatchConfig:
	var coop: bool = _args["mode"] == "coop"
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP if coop else MatchConfig.Mode.VERSUS_CPU)
	cfg.round_time_seconds = 0
	cfg.rng_seed = _args["seed"]
	if coop:
		cfg.coop = CoopConfig.new()
		cfg.coop.enemy_count = _args["enemies"] * QUEUE_FACTOR
		cfg.coop.enemy_level = _args["enemy_level"]
	var ids := CharacterRegistry.IDS
	for i in _args["humans"]:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = ids[i % ids.size()]
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = _args["level"]
		cfg.players.append(p)
	return cfg


func _bench() -> bool:
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(_config())
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in _args["warmup"]:
		d.step()
	var warm := d.save_state()
	var rb: int = _args["rollback"]
	var step_us: Array[int] = []
	var save_us: Array[int] = []
	var load_us: Array[int] = []
	var ser_us: Array[int] = []
	var resim_us: Array[int] = []
	var bytes: Array[int] = []
	var fighters: Array[int] = []
	var ring: Array[Dictionary] = []  # last `rb` pre-step snapshots, oldest first
	var restarts := 0
	var checks := 0
	var mismatches := 0
	for i in _args["ticks"]:
		if d.phase != MatchDirector.Phase.FIGHT:
			d.load_state(warm)
			ring.clear()
			restarts += 1
		# Snapshot (what the rollback driver does every tick before stepping).
		var t := Time.get_ticks_usec()
		var snap := d.save_state()
		save_us.append(Time.get_ticks_usec() - t)
		ring.append(snap)
		if ring.size() > rb:
			ring.pop_front()
		t = Time.get_ticks_usec()
		var buf := var_to_bytes(snap)
		var _h := hash(buf)
		ser_us.append(Time.get_ticks_usec() - t)
		bytes.append(buf.size())
		t = Time.get_ticks_usec()
		d.step()
		step_us.append(Time.get_ticks_usec() - t)
		fighters.append(d.fighters.size())
		# Every `rb` ticks: roll back to the oldest snapshot and re-simulate.
		if ring.size() == rb and i % rb == rb - 1 and d.phase == MatchDirector.Phase.FIGHT:
			var straight := var_to_bytes(d.save_state())
			t = Time.get_ticks_usec()
			d.load_state(ring[0])
			load_us.append(Time.get_ticks_usec() - t)
			d.resimulating = true
			for k in rb:
				d.step()
			d.resimulating = false
			resim_us.append(Time.get_ticks_usec() - t)
			checks += 1
			if var_to_bytes(d.save_state()) != straight:
				mismatches += 1
	d.queue_free()

	var s_step := _stats(step_us)
	var s_save := _stats(save_us)
	var s_load := _stats(load_us)
	var s_ser := _stats(ser_us)
	var s_rb := _stats(resim_us)
	var s_bytes := _stats(bytes, 1.0)
	var mean_fighters: float = _stats(fighters, 1.0)["mean"]
	var est_mean: float = rb * s_step["mean"] + s_save["mean"] + s_load["mean"]
	var est_p95: float = rb * s_step["p95"] + s_save["p95"] + s_load["p95"]
	# The real driver also snapshots every re-simulated tick.
	var full_p95: float = rb * (s_step["p95"] + s_save["p95"]) + s_load["p95"]
	print("fighters on field %.1f (field_cap %d), %d samples, %d restarts" % [
		mean_fighters, Tuning.coop.field_cap, step_us.size(), restarts])
	print("%-22s %8s %8s %8s %8s" % ["ms", "mean", "p50", "p95", "max"])
	for row: Array in [["step", s_step], ["save_state", s_save], ["load_state", s_load],
			["var_to_bytes+hash", s_ser], ["rollback %d (load+re-step)" % rb, s_rb]]:
		var st: Dictionary = row[1]
		print("%-22s %8.3f %8.3f %8.3f %8.3f" % [row[0], st["mean"], st["p50"], st["p95"], st["max"]])
	print("%-22s %8.0f %8.0f %8.0f %8.0f" % ["snapshot bytes", s_bytes["mean"], s_bytes["p50"], s_bytes["p95"], s_bytes["max"]])
	print("budget %d×step+save+load: mean %.2f ms, p95 %.2f ms (budget %.1f ms) %s" % [
		rb, est_mean, est_p95, BUDGET_MS, "OK" if est_p95 <= BUDGET_MS else "OVER"])
	print("with a save per re-simulated tick, %d×(step+save)+load: p95 %.2f ms %s" % [
		rb, full_p95, "OK" if full_p95 <= BUDGET_MS else "OVER"])
	var det := "OK" if mismatches == 0 and checks > 0 else "MISMATCH"
	print("determinism: %s (%d/%d rollbacks re-simulated identically)" % [det, checks - mismatches, checks])
	print("NET_BENCH mode=%s humans=%d enemies=%d fighters=%.1f rollback=%d step_mean=%.3f step_p95=%.3f save_mean=%.3f save_p95=%.3f load_mean=%.3f load_p95=%.3f ser_mean=%.3f bytes=%d rb_mean=%.3f rb_p95=%.3f est_mean=%.2f est_p95=%.2f full_p95=%.2f budget=%.1f det=%s" % [
		_args["mode"], _args["humans"], _args["enemies"] if _args["mode"] == "coop" else 0, mean_fighters, rb, s_step["mean"], s_step["p95"],
		s_save["mean"], s_save["p95"], s_load["mean"], s_load["p95"], s_ser["mean"], int(s_bytes["mean"]),
		s_rb["mean"], s_rb["p95"], est_mean, est_p95, full_p95, BUDGET_MS, det])
	return det == "OK"


## mean/p50/p95/max of samples, scaled (µs -> ms by default).
func _stats(samples: Array[int], scale: float = 0.001) -> Dictionary:
	if samples.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
	var s := samples.duplicate()
	s.sort()
	var total := 0
	for v in s:
		total += v
	var at := func(q: float) -> float: return s[mini(int(q * s.size()), s.size() - 1)] * scale
	return {"mean": total * scale / s.size(), "p50": at.call(0.5), "p95": at.call(0.95), "max": s[-1] * scale}
