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
##
## driver=1 (default) then runs the same match online: one peer per human
## slot over a LoopbackNetwork (`latency` one-way ms, `jitter` ms, `loss` %,
## `delay` = input delay, -1 = TimeSync.auto_input_delay of the worst round
## trip), every peer a real RollbackDriver with a CpuInput as its "pad"
## (CPU humans at `level`). It times each peer's advance() (pump, rollback,
## local step, the snapshots the driver really takes) and reports the slowest
## peer, the rollback depths seen and the snapshots taken/skipped. The config
## is online, so Tuning.coop.online_field_cap applies there: it is raised to
## the bench's field cap for the run. driver=0 skips it.

## Per-frame budget for rollback work (ms): half a 60 Hz frame (§12).
const BUDGET_MS := 8.0
## Brawl queue = enemies × this, so KO'd enemies keep being replaced.
const QUEUE_FACTOR := 1000

var _args := {"mode": "coop", "humans": 2, "enemies": 4, "ticks": 1800, "warmup": 600,
	"rollback": -1, "seed": 7, "level": 7, "enemy_level": 3,
	"driver": 1, "latency": 60, "jitter": 10, "loss": 2, "delay": -1}
## Frames (each peer's advance()) before the driver run is timed.
const DRIVER_WARMUP_FRAMES := 300
## Handshake frames before the driver run gives up.
const CONNECT_FRAMES := 300


func _ready() -> void:
	for a in ToolArgs.pairs():
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
	if ok and _args["driver"] != 0:
		ok = _bench_driver()
	print("NET_BENCH DONE %s" % ("OK" if ok else "FAIL"))
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
	_offline_p95 = {"step": s_step["p95"], "save": s_save["p95"], "load": s_load["p95"]}
	var det := "OK" if mismatches == 0 and checks > 0 else "MISMATCH"
	print("determinism: %s (%d/%d rollbacks re-simulated identically)" % [det, checks - mismatches, checks])
	print("NET_BENCH mode=%s humans=%d enemies=%d fighters=%.1f rollback=%d step_mean=%.3f step_p95=%.3f save_mean=%.3f save_p95=%.3f load_mean=%.3f load_p95=%.3f ser_mean=%.3f bytes=%d rb_mean=%.3f rb_p95=%.3f est_mean=%.2f est_p95=%.2f full_p95=%.2f budget=%.1f det=%s" % [
		_args["mode"], _args["humans"], _args["enemies"] if _args["mode"] == "coop" else 0, mean_fighters, rb, s_step["mean"], s_step["p95"],
		s_save["mean"], s_save["p95"], s_load["mean"], s_load["p95"], s_ser["mean"], int(s_bytes["mean"]),
		s_rb["mean"], s_rb["p95"], est_mean, est_p95, full_p95, BUDGET_MS, det])
	return det == "OK"


## Offline p95s (ms) of step/save/load, for the driver run's estimate.
var _offline_p95 := {"step": 0.0, "save": 0.0, "load": 0.0}


## The same match online: a LoopbackNetwork room, one peer per human slot,
## each with a RollbackDriver. Times every peer's advance() per frame.
func _bench_driver() -> bool:
	var cfg := _config()
	var coop: bool = _args["mode"] == "coop"
	if not coop:
		cfg.mode = MatchConfig.Mode.ONLINE
		cfg.rounds_to_win = MatchConfig.MAX_ROUNDS_TO_WIN  # rounds restart; keep going
	for p in cfg.players:
		p.owner_peer = Transport.HOST_PEER + p.slot
		p.display_name = "P%d" % p.slot
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL
	var saved_cap := Tuning.coop.online_field_cap
	Tuning.coop.online_field_cap = Tuning.coop.field_cap
	var n: int = _args["humans"]
	var net := LoopbackNetwork.new(_args["seed"])
	var ht := net.create_host()
	var sessions: Array[Session] = [Session.create_host(ht, "Host")]
	for i in n - 1:
		var gt := net.create_client()
		sessions.append(Session.create_guest(gt, "Guest%d" % (i + 1)))
		net.connect_client(gt, ht)
	for s in sessions:
		s.clock = net.now_ms
	var connected := false
	for i in CONNECT_FRAMES:
		net.advance_frame()
		connected = true
		for s in sessions:
			s.update()
			connected = connected and s.state == Session.State.CONNECTED
		if connected:
			break
	if not connected:
		print("driver: handshake failed")
		return false
	net.latency_ms = _args["latency"]
	net.jitter_ms = _args["jitter"]
	net.loss_percent = _args["loss"]
	# Worst round trip a local input makes: guest -> host -> guest past 2 peers.
	var rtt: float = 2.0 * (_args["latency"] + _args["jitter"]) * (2 if n > 2 else 1)
	var delay: int = _args["delay"] if _args["delay"] >= 0 else TimeSync.auto_input_delay(rtt)
	var wire := cfg.to_dict()
	var drivers: Array[RollbackDriver] = []
	for s in sessions:
		var d := MatchDirector.new()
		add_child(d)
		var drv := RollbackDriver.new()
		drv.auto_run = false
		add_child(drv)
		var local := {}
		for p in cfg.players:
			if p.owner_peer == s.local_peer_id:
				local[p.slot] = CpuInput.new(_args["level"])
		drv.start(d, s, MatchConfig.from_dict(wire), local, delay)
		for slot: int in local:
			(local[slot] as CpuInput).attach(d, slot)
		drivers.append(drv)
	var rb: int = drivers[0].max_rollback_frames
	var frame_us: Array = []  # per peer: Array[int] of advance() µs
	for drv in drivers:
		frame_us.append([] as Array[int])
	var depth_us := {}  # rollback depth -> Array[int] of advance() µs (every peer)
	for k in rb + 1:
		depth_us[k] = [] as Array[int]
	var depths: Array[int] = []
	var fighters: Array[int] = []
	var frames := 0
	var i := 0
	while frames < int(_args["ticks"]):
		var phase := drivers[0].director.phase
		if phase == MatchDirector.Phase.MATCH_OVER:
			break
		# Only fight frames count (intro/outro are cheap and roll back little).
		var timed := i >= DRIVER_WARMUP_FRAMES and phase == MatchDirector.Phase.FIGHT
		i += 1
		net.advance_frame()
		for k in drivers.size():
			var drv := drivers[k]
			var before := drv.rollback_ticks
			var t := Time.get_ticks_usec()
			drv.advance()
			var us := Time.get_ticks_usec() - t
			if not timed:
				continue
			var depth := mini(drv.rollback_ticks - before, rb)
			(frame_us[k] as Array[int]).append(us)
			(depth_us[depth] as Array[int]).append(us)
			depths.append(depth)
		if timed:
			frames += 1
			fighters.append(drivers[0].director.fighters.size())
	# Determinism: every peer's confirmed checkpoint hashes agree, no resyncs.
	var checks := 0
	var mismatches := 0
	var resyncs := 0
	for drv in drivers:
		resyncs += drv.resyncs
		for tick: int in drv.confirmed_hashes:
			if drivers[0].confirmed_hashes.has(tick):
				checks += 1
				if drv.confirmed_hashes[tick] != drivers[0].confirmed_hashes[tick]:
					mismatches += 1
	var worst := 0
	var worst_stats := _stats(frame_us[0])
	for k in drivers.size():
		var st := _stats(frame_us[k])
		if st["p95"] > worst_stats["p95"]:
			worst = k
			worst_stats = st
	var s_depth := _stats(depths, 1.0)
	var deep_n: int = (depth_us[rb] as Array[int]).size()
	var deep := _stats(depth_us[rb])
	# A depth-rb frame as the driver runs it: load, rb re-steps each followed
	# by a save, then the new tick's step + save (offline p95s).
	var deep_est: float = (rb + 1) * (_offline_p95["step"] + _offline_p95["save"]) + _offline_p95["load"]
	print("driver: %d peers, latency %d±%d ms, loss %d%%, input delay %d, %d frames, %.1f fighters" % [
		n, _args["latency"], _args["jitter"], _args["loss"], delay, frames, _stats(fighters, 1.0)["mean"]])
	print("rollback depth per peer-frame: mean %.2f p95 %d max %d; %.1f%% of peer-frames at depth %d" % [
		s_depth["mean"], int(s_depth["p95"]), int(s_depth["max"]), 100.0 * deep_n / maxi(depths.size(), 1), rb])
	for k in rb + 1:
		var arr: Array[int] = depth_us[k]
		if not arr.is_empty():
			var st := _stats(arr)
			print("  depth %d: %6d peer-frames, advance() mean %.2f p95 %.2f max %.2f ms" % [
				k, arr.size(), st["mean"], st["p95"], st["max"]])
	print("slowest peer (#%d) advance(): mean %.2f p50 %.2f p95 %.2f max %.2f ms" % [
		worst, worst_stats["mean"], worst_stats["p50"], worst_stats["p95"], worst_stats["max"]])
	if deep_n > 0:
		print("Full (driver), measured depth-%d frame: p95 %.2f ms %s (offline est. %d×(step+save)+load %.2f ms)" % [
			rb, deep["p95"], "OK" if deep["p95"] <= BUDGET_MS else "OVER", rb + 1, deep_est])
	else:
		print("Full (driver): no depth-%d rollback in this run (raise latency / delay=0); offline est. %d×(step+save)+load %.2f ms" % [
			rb, rb + 1, deep_est])
	var det := "OK" if mismatches == 0 and checks > 0 and resyncs == 0 else "MISMATCH"
	print("driver determinism: %s (%d checkpoint hashes compared, %d resyncs)" % [det, checks, resyncs])
	print("NET_BENCH_DRIVER mode=%s humans=%d fighters=%.1f latency=%d jitter=%d loss=%d delay=%d frames=%d depth_mean=%.2f depth_p95=%d deep_pct=%.1f frame_mean=%.3f frame_p95=%.3f frame_max=%.3f deep_mean=%.3f deep_p95=%.3f deep_est=%.2f budget=%.1f det=%s" % [
		_args["mode"], n, _stats(fighters, 1.0)["mean"], _args["latency"], _args["jitter"], _args["loss"], delay,
		frames, s_depth["mean"], int(s_depth["p95"]), 100.0 * deep_n / maxi(depths.size(), 1),
		worst_stats["mean"], worst_stats["p95"], worst_stats["max"], deep["mean"], deep["p95"], deep_est,
		BUDGET_MS, det])
	for drv in drivers:
		drv.director.queue_free()
		drv.queue_free()
	Tuning.coop.online_field_cap = saved_cap
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
