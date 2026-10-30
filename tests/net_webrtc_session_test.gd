extends Node
## The existing Session + RollbackDriver over WebRtcTransport (real WebRTC
## through webrtc-native, LocalSignaling in-process): handshake and WELCOME
## for a host and two guests, a failed join ending the guest's session at
## once (not after the session timeout), short rollback matches (versus FFA
## and co-op) whose confirmed checkpoints equal an offline reference sim, a
## RESYNC snapshot of a full co-op field crossing the chunked BULK channel,
## and the size of the largest RELIABLE / BULK messages (INFO lines).
## Run as a scene:  godot --headless res://tests/net_webrtc_session_test.tscn

const GAME := "2:test"
const MAX_FRAMES := 600
const FRAME_MS := 2
## Frames each match runs.
const FRAMES := 360
const DELAY := 2
## Size probe: fighters on the field (Tuning.coop.field_cap range max),
## enemies queued and ticks simulated, sampled every checksum interval.
const PROBE_FIELD := 16
const PROBE_ENEMIES := 30
const PROBE_TICKS := 1800

var _failures := 0


class DelayedTick extends TickInput:
	var delay: int = 0

	func _init(p_seed: int, p_delay: int) -> void:
		super(p_seed)
		delay = p_delay

	func _sample(tick: int) -> InputFrame:
		return InputFrame.new() if tick <= delay else super(tick)


func _ready() -> void:
	_test_handshake_and_versus()
	_test_failed_join()
	_test_coop_and_resync()
	_measure_sizes()
	print("NET WEBRTC SESSION TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- harness ------------------------------------------------------------------

## Host + `guests` guests through LocalSignaling; returns the sessions (host
## first) once every guest is welcomed, or [] on failure.
func _room(guests: int) -> Array[Session]:
	var hub := LocalSignaling.new()
	var ht := WebRtcTransport.new()
	ht.host_room(hub.create_client(), GAME, guests)
	var host := Session.create_host(ht, "Host")
	var sessions: Array[Session] = [host]
	for i in MAX_FRAMES:
		host.update()
		if not ht.room_code().is_empty():
			break
		OS.delay_msec(FRAME_MS)
	for i in guests:
		var gt := WebRtcTransport.new()
		gt.join_room(hub.create_client(), ht.room_code(), GAME)
		sessions.append(Session.create_guest(gt, "Guest%d" % (i + 1)))
	for i in MAX_FRAMES:
		var ok := true
		for s in sessions:
			s.update()
			ok = ok and s.state == Session.State.CONNECTED
		if ok:
			return sessions
		OS.delay_msec(FRAME_MS)
	return [] as Array[Session]


static func _config(humans: int, coop: bool) -> MatchConfig:
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
	return cfg


## One driver per session; returns [{session, director, driver}].
func _start(sessions: Array[Session], cfg: MatchConfig) -> Array:
	for c in get_children():
		c.queue_free()
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
			if p.owner_peer == s.local_peer_id:
				local[p.slot] = TickInput.new(100 + p.slot)
		drv.start(d, s, MatchConfig.from_dict(wire), local, DELAY)
		peers.append({"session": s, "director": d, "driver": drv})
	return peers


func _run(peers: Array, frames: int) -> void:
	for i in frames:
		for p: Dictionary in peers:
			(p["driver"] as RollbackDriver).advance()
		OS.delay_msec(FRAME_MS)


func _reference(cfg: MatchConfig, ticks: int) -> Dictionary:
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		return DelayedTick.new(100 + p.slot, DELAY)
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


## Every peer's confirmed checkpoints equal the reference (and there are some).
func _match_reference(peers: Array, ref: Dictionary, label: String) -> void:
	var bad := []
	var fewest := 1 << 30
	for p: Dictionary in peers:
		var drv: RollbackDriver = p["driver"]
		var n := 0
		for t: int in drv.confirmed_hashes:
			n += 1
			if ref.get(t, -1) != drv.confirmed_hashes[t]:
				bad.append([(p["session"] as Session).local_peer_id, t])
		fewest = mini(fewest, n)
	_check(bad.is_empty() and fewest >= Tuning.net.checkpoints_kept,
		"%s: every peer's confirmed checkpoints equal the offline sim (fewest %d) %s" % [label, fewest, str(bad.slice(0, 4))])
	var resyncs := 0
	for p: Dictionary in peers:
		resyncs += (p["driver"] as RollbackDriver).resyncs
	_check(resyncs == 0, "%s: no resyncs" % label)


func _close(sessions: Array[Session]) -> void:
	for s in sessions:
		s.close()


# --- tests --------------------------------------------------------------------

func _test_handshake_and_versus() -> void:
	var sessions := _room(2)
	if not _check(not sessions.is_empty(), "handshake: host + 2 guests welcomed over WebRTC"):
		return
	_check(sessions[1].local_peer_id == 2 and sessions[2].local_peer_id == 3
		and sessions[0].peer_ids() == ([1, 2, 3] as Array[int]) and sessions[2].peer_name(2) == "Guest1",
		"handshake: WELCOME ids 2, 3 and the name table reach everyone")
	var cfg := _config(3, false)
	var peers := _start(sessions, cfg)
	_run(peers, FRAMES)
	_match_reference(peers, _reference(cfg, FRAMES + 1), "versus FFA 3 peers")
	_close(sessions)


func _test_failed_join() -> void:
	var hub := LocalSignaling.new()
	var gt := WebRtcTransport.new()
	gt.join_room(hub.create_client(), "ABCDEF", GAME)
	var s := Session.create_guest(gt, "Lost")
	var ended := []
	s.session_ended.connect(func(r: int) -> void: ended.append(r))
	var frames := 0
	while ended.is_empty() and frames < MAX_FRAMES:
		s.update()
		frames += 1
	_check(ended == [Protocol.Reason.DISCONNECTED] and frames < Tuning.net.disconnect_timeout_frames
		and gt.last_error_text() == "No room with that code",
		"failed join: session ends with DISCONNECTED after %d frames ('%s')" % [frames, gt.last_error_text()])


func _test_coop_and_resync() -> void:
	var sessions := _room(1)
	if not _check(not sessions.is_empty(), "co-op: host + guest welcomed"):
		return
	var cfg := _config(2, true)
	var peers := _start(sessions, cfg)
	_run(peers, FRAMES)
	_match_reference(peers, _reference(cfg, FRAMES + 1), "co-op 2 peers")
	# a full-field snapshot as a RESYNC on the BULK channel
	var d: MatchDirector = peers[0]["director"]
	var snap := d.save_state()
	var got := []
	sessions[1].resync_received.connect(func(t: int, sn: Dictionary) -> void: got.append([t, sn]))
	_check(sessions[0].send_resync(2, d.tick, snap), "co-op: RESYNC encoded (%d bytes)" % Protocol.encode_resync(d.tick, snap).size())
	for i in MAX_FRAMES:
		if not got.is_empty():
			break
		sessions[0].update()
		sessions[1].update()
		OS.delay_msec(FRAME_MS)
	_check(got.size() == 1 and got[0][0] == d.tick and StateHash.of_state(got[0][1]) == StateHash.of_state(snap),
		"co-op: the RESYNC snapshot arrives intact")
	_close(sessions)
	for c in get_children():
		c.queue_free()


## Largest RESYNC (BULK) and MATCH_START (RELIABLE) seen in a crowded
## co-op run, at the online field cap and at the range max of field_cap;
## informational (printed), checked only against the caps.
func _measure_sizes() -> void:
	var saved := [Tuning.coop.field_cap, Tuning.coop.online_field_cap]
	for cap: int in [Tuning.coop.online_field_cap, PROBE_FIELD]:
		Tuning.coop.field_cap = cap
		Tuning.coop.online_field_cap = cap
		_measure_at(cap)
	Tuning.coop.field_cap = saved[0]
	Tuning.coop.online_field_cap = saved[1]


func _measure_at(cap: int) -> void:
	var cfg := _config(2, true)
	cfg.coop.enemy_count = PROBE_ENEMIES
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		return TickInput.new(100 + p.slot)
	add_child(d)
	d.setup(MatchConfig.from_dict(cfg.to_dict()))
	var max_bulk := 0
	var max_raw := 0
	var max_fighters := 0
	while d.tick < PROBE_TICKS and d.phase != MatchDirector.Phase.MATCH_OVER:
		d.step()
		if d.tick % Tuning.net.checksum_interval == 0:
			var st := d.save_state()
			max_raw = maxi(max_raw, var_to_bytes(st).size())
			max_bulk = maxi(max_bulk, Protocol.encode_resync(d.tick, st).size())
			max_fighters = maxi(max_fighters, d.fighters.size())
	var start := Protocol.encode_match_start(cfg.to_dict(), cfg.rng_seed)
	print("INFO field cap %d: largest RESYNC %d bytes on the wire (%d raw var_to_bytes), up to %d fighters; MATCH_START %d bytes; chunks of %d"
		% [cap, max_bulk, max_raw, max_fighters, start.size(), Tuning.net.webrtc_chunk_bytes])
	_check(max_bulk > 0 and max_bulk < Tuning.net.max_bulk_bytes and not start.is_empty(),
		"sizes (field cap %d): RESYNC and MATCH_START fit their caps" % cap)
	remove_child(d)
	d.queue_free()
