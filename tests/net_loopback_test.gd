extends Node
## Rollback over LoopbackTransport (SPEC_ONLINE.md §7, §16 net_loopback_test):
## 2-4 directors in one process, each driven by a RollbackDriver, under
## latency, jitter and loss. Every peer's confirmed checkpoint hashes must
## equal an offline reference sim fed the same inputs (so prediction +
## rollback converge to the real timeline), a silent peer stalls the others,
## and a peer leaving a versus match forfeits it on every remaining peer.
## Run as a scene:  godot --headless res://tests/net_loopback_test.tscn

## Frames each run lasts.
const FRAMES := 600
## Frames after which a silent peer must have stalled the host.
const SILENT_FRAMES := 120

var _failures := 0


## Offline stand-in for a local slot online: neutral for ticks 1..delay (the
## driver submits those itself), TickInput afterwards.
class DelayedTick extends TickInput:
	var delay: int = 0

	func _init(p_seed: int, p_delay: int) -> void:
		super(p_seed)
		delay = p_delay

	func _sample(tick: int) -> InputFrame:
		return InputFrame.new() if tick <= delay else super(tick)


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_converges.bind(2, 0, 0.0, 0.0, 0.0, false),
		_test_converges.bind(2, 2, 50.0, 10.0, 5.0, false),
		_test_converges.bind(2, 3, 150.0, 30.0, 10.0, false),
		_test_converges.bind(4, 1, 0.0, 0.0, 0.0, false),
		# guest -> host -> guest is two hops: auto delay from that round trip
		_test_converges.bind(4, TimeSync.auto_input_delay(4 * 80.0), 80.0, 20.0, 5.0, true),
		_test_converges_coop,
		_test_commands_over_network,
		_test_silent_peer_stalls,
		_test_leave_forfeits,
	]
	for t in tests:
		t.call()
	print("NET LOOPBACK TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- harness ------------------------------------------------------------------

## `humans` human slots (slot i owned by peer i: host = 1, guests 2..), plus
## a CPU slot when `with_cpu`. Versus FFA unless coop.
static func _config(humans: int, with_cpu: bool, coop: bool = false) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP if coop else MatchConfig.Mode.ONLINE)
	cfg.rng_seed = 7
	cfg.round_time_seconds = 0
	if coop:
		cfg.coop = CoopConfig.new()
		cfg.coop.structure = CoopConfig.Structure.BRAWL
		cfg.coop.enemy_count = 6
	for i in humans:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = Transport.HOST_PEER + i
		p.display_name = "P%d" % i
		cfg.players.append(p)
	if with_cpu:
		var c := PlayerSlotConfig.new()
		c.slot = humans
		c.input_kind = PlayerSlotConfig.InputKind.CPU
		cfg.players.append(c)
	return cfg


## Connected room of `n` peers running `cfg`; returns {net, peers: [{session,
## director, driver}]} or {} if the handshake failed.
func _room(n: int, cfg: MatchConfig, delay: int, latency: float, jitter: float, loss: float) -> Dictionary:
	for c in get_children():
		c.queue_free()
	var net := LoopbackNetwork.new(11)
	var ht := net.create_host()
	var sessions: Array[Session] = [Session.create_host(ht, "Host")]
	for i in n - 1:
		var gt := net.create_client()
		sessions.append(Session.create_guest(gt, "Guest%d" % (i + 1)))
		net.connect_client(gt, ht)
	for s in sessions:
		s.clock = net.now_ms
	var connected := false
	for i in 300:
		net.advance_frame()
		connected = true
		for s in sessions:
			s.update()
			connected = connected and s.state == Session.State.CONNECTED
		if connected:
			break
	if not connected:
		return {}
	net.latency_ms = latency
	net.jitter_ms = jitter
	net.loss_percent = loss
	var wire := cfg.to_dict()
	var peers: Array = []
	for s in sessions:
		var d := MatchDirector.new()
		add_child(d)
		var drv := RollbackDriver.new()
		drv.auto_run = false
		add_child(drv)
		var local := {}
		for p in cfg.players:
			if p.owner_peer == s.local_peer_id and p.input_kind != PlayerSlotConfig.InputKind.CPU:
				local[p.slot] = TickInput.new(100 + p.slot)
		var hub := MatchEventHub.new()
		add_child(hub)
		drv.start(d, s, MatchConfig.from_dict(wire), local, delay, hub)
		peers.append({"session": s, "director": d, "driver": drv, "hub": hub})
	return {"net": net, "peers": peers}


func _run(room: Dictionary, frames: int) -> void:
	var net: LoopbackNetwork = room["net"]
	for i in frames:
		net.advance_frame()
		for p: Dictionary in room["peers"]:
			(p["driver"] as RollbackDriver).advance()


## Checkpoint hashes of the straight offline sim of `cfg` up to `ticks`.
func _reference(cfg: MatchConfig, delay: int, ticks: int) -> Dictionary:
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			return p.create_input_source()
		return DelayedTick.new(100 + p.slot, delay)
	add_child(d)
	d.setup(MatchConfig.from_dict(cfg.to_dict()))
	var out := {}
	while d.tick < ticks:
		d.step()
		if d.tick % Tuning.net.checksum_interval == 0:
			out[d.tick] = StateHash.of(d)
	remove_child(d)
	d.queue_free()
	return out


## Every peer's confirmed checkpoints match the reference; returns how many
## checkpoints the slowest peer confirmed.
func _match_reference(room: Dictionary, ref: Dictionary, label: String) -> int:
	var fewest := 1 << 30
	var bad := []
	for p: Dictionary in room["peers"]:
		var drv: RollbackDriver = p["driver"]
		var n := 0
		for t: int in drv.confirmed_hashes:
			n += 1
			if ref.get(t, -1) != drv.confirmed_hashes[t]:
				bad.append([(p["session"] as Session).local_peer_id, t])
		fewest = mini(fewest, n)
	_check(bad.is_empty(), "%s: every confirmed checkpoint equals the offline sim %s" % [label, str(bad.slice(0, 4))])
	return fewest


# --- tests --------------------------------------------------------------------

func _test_converges(n: int, delay: int, latency: float, jitter: float, loss: float, with_cpu: bool) -> void:
	var label := "%d peers%s delay %d %d/%d ms %d%%" % [n, " + CPU" if with_cpu else "", delay, latency, jitter, loss]
	var cfg := _config(n, with_cpu)
	var room := _room(n, cfg, delay, latency, jitter, loss)
	if not _check(not room.is_empty(), "%s: room connected" % label):
		return
	_run(room, FRAMES)
	var ref := _reference(cfg, delay, FRAMES + 1)
	var kept := mini(Tuning.net.checkpoints_kept, FRAMES / Tuning.net.checksum_interval)
	var host: RollbackDriver = room["peers"][0]["driver"]
	var fewest := _match_reference(room, ref, label)
	_check(fewest >= kept, "%s: checkpoints confirmed on every peer (%d)" % [label, fewest])
	var min_tick := 1 << 30
	var resyncs := 0
	var rollbacks := 0
	for p: Dictionary in room["peers"]:
		var drv: RollbackDriver = p["driver"]
		min_tick = mini(min_tick, (p["director"] as MatchDirector).tick)
		resyncs += drv.resyncs
		rollbacks += drv.rollbacks
	_check(min_tick >= FRAMES * 0.85, "%s: sims kept pace (slowest at tick %d of %d frames)" % [label, min_tick, FRAMES])
	_check(resyncs == 0, "%s: no desync resyncs" % label)
	var hubs_ok := true
	for p: Dictionary in room["peers"]:
		hubs_ok = hubs_ok and (p["hub"] as MatchEventHub).confirmed_tick == (p["driver"] as RollbackDriver).confirmed_tick
	_check(hubs_ok, "%s: event hubs confirmed in step with the drivers" % label)
	if latency > 0.0:
		_check(rollbacks > 0, "%s: mispredictions were rolled back (%d)" % [label, rollbacks])
	_check(host.confirmed_tick >= FRAMES - 60, "%s: host confirmed up to %d" % [label, host.confirmed_tick])


func _test_converges_coop() -> void:
	var label := "co-op 2 peers delay 2 60/15 ms 5%"
	var cfg := _config(2, false, true)
	var room := _room(2, cfg, 2, 60.0, 15.0, 5.0)
	if not _check(not room.is_empty(), "%s: room connected" % label):
		return
	_run(room, FRAMES)
	var ref := _reference(cfg, 2, FRAMES + 1)
	_match_reference(room, ref, label)
	var d: MatchDirector = room["peers"][1]["director"]
	_check(d.fighters.size() > 2, "%s: enemies spawned on the guest (%d fighters)" % [label, d.fighters.size()])


## Host-issued CPU_TAKEOVER then RECLAIM of the guest's slot under latency:
## both peers apply them at the same tick and agree on every checkpoint.
func _test_commands_over_network() -> void:
	var cfg := _config(2, false, true)
	var room := _room(2, cfg, 2, 50.0, 10.0, 5.0)
	if not _check(not room.is_empty(), "commands: room connected"):
		return
	var host: RollbackDriver = room["peers"][0]["driver"]
	var guest: RollbackDriver = room["peers"][1]["driver"]
	_run(room, 150)
	var t1 := host.issue_command({"kind": MatchDirector.CommandKind.CPU_TAKEOVER, "slot": 1, "cpu_level": 3})
	_run(room, 150)
	var gd: MatchDirector = room["peers"][1]["director"]
	_check(gd.controller_for_slot(1) == MatchDirector.Controller.CPU, "commands: guest applied CPU_TAKEOVER (tick %d)" % t1)
	host.issue_command({"kind": MatchDirector.CommandKind.RECLAIM, "slot": 1, "peer": 2})
	_run(room, 150)
	_check(gd.controller_for_slot(1) == MatchDirector.Controller.PLAYER, "commands: guest applied RECLAIM")
	var n := 0
	var same := true
	for t: int in host.confirmed_hashes:
		if guest.confirmed_hashes.has(t):
			n += 1
			same = same and host.confirmed_hashes[t] == guest.confirmed_hashes[t]
	_check(n >= 2 and same, "commands: peers agree on every common checkpoint (%d)" % n)
	_check(host.resyncs == 0, "commands: no resyncs")


func _test_silent_peer_stalls() -> void:
	var cfg := _config(2, false)
	var room := _room(2, cfg, 1, 30.0, 0.0, 0.0)
	if not _check(not room.is_empty(), "stall: room connected"):
		return
	_run(room, 60)
	var net: LoopbackNetwork = room["net"]
	var host: Dictionary = room["peers"][0]
	var guest: Dictionary = room["peers"][1]
	var guest_t: Transport = (guest["session"] as Session).transport
	net.set_silent(guest_t, true)
	var drv: RollbackDriver = host["driver"]
	var d: MatchDirector = host["director"]
	for i in SILENT_FRAMES:
		net.advance_frame()
		drv.advance()
	var oldest := (host["session"] as Session).history.last_confirmed_tick(1)
	_check(d.tick - oldest <= Tuning.net.max_rollback_frames,
		"stall: host stops within max_rollback_frames of the silent guest's input (tick %d, guest input %d)" % [d.tick, oldest])
	_check(drv.stalled_for > Tuning.net.stall_warning_frames and drv.waiting_for() == "Guest1",
		"stall: 'Waiting for Guest1' after stall_warning_frames (%s)" % drv.waiting_for())
	net.set_silent(guest_t, false)
	_run(room, 90)
	_check(drv.stalled_for == 0 and d.tick > oldest + Tuning.net.max_rollback_frames,
		"stall: resumes when the guest is heard again (tick %d)" % d.tick)


func _test_leave_forfeits() -> void:
	var cfg := _config(3, false)
	var room := _room(3, cfg, 2, 40.0, 5.0, 0.0)
	if not _check(not room.is_empty(), "forfeit: room connected"):
		return
	_run(room, 120)
	var net: LoopbackNetwork = room["net"]
	var leaver: Session = room["peers"][2]["session"]
	leaver.close()
	var rest: Array = room["peers"].slice(0, 2)
	for i in 120:
		net.advance_frame()
		for p: Dictionary in rest:
			(p["driver"] as RollbackDriver).advance()
	var hashes := []
	for p: Dictionary in rest:
		var d: MatchDirector = p["director"]
		var drv: RollbackDriver = p["driver"]
		_check(d.phase == MatchDirector.Phase.MATCH_OVER and d.end_reason == &"forfeit",
			"forfeit: peer %d ends the match by forfeit" % (p["session"] as Session).local_peer_id)
		_check(drv.confirmed_tick >= d.tick - Tuning.net.max_rollback_frames,
			"forfeit: peer %d keeps confirming without the leaver (%d / %d)" % [(p["session"] as Session).local_peer_id, drv.confirmed_tick, d.tick])
		var last := -1
		for t: int in drv.confirmed_hashes:
			last = maxi(last, t)
		hashes.append([last, drv.confirmed_hashes.get(last)])
	_check(hashes[0] == hashes[1], "forfeit: both peers agree on the last checkpoint %s" % str(hashes))
