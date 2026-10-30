extends Node
## One peer of a real online match over WebRTC through a signaling server,
## for the desktop <-> browser cross-play check (tools/crossplay_e2e.sh,
## docs/web_online.md "Cross-play end-to-end check"). Runs on desktop
##   godot --headless res://tools/web_tools.tscn -- tool=net_peer role=host signal=ws://127.0.0.1:18765
## and in the "Web Tools" export (?tool=net_peer&role=guest&code=ABCDEF&...).
## Args (ToolArgs): role=host|guest, signal=<ws url>, code=<room code,
## guest>, mode=versus|coop, ticks=N (confirmed ticks to play), seed,
## delay (input delay), level (CPU level of the "pads"), enemies (co-op
## field), timeout (seconds to connect).
## The host opens a room (WebRtcTransport + SignalingClient, the same as
## Net.host_room) and prints `NET_PEER CODE <code>`; the guest joins by code.
## Both then run a Session + RollbackDriver match (the setup of
## tests/net_webrtc_session_test): every slot is a human owned by one of the
## two peers, its "pad" a CpuInput, so real inputs cross the wire and get
## predicted / rolled back. Both build the same MatchConfig from the args
## (and apply the web caps when a browser is in the session, as the room
## does). Prints `NET_PEER HASH <tick> <hash>` per confirmed checkpoint and
## `NET_PEER DONE OK|FAIL ...` (rollbacks, resyncs, RTT); then keeps
## pumping for LINGER_FRAMES so the far side can confirm too, and quits.
## Everything runs one step per physics frame (no blocking loop), so it works
## in the browser's main loop.

const PREFIX := "NET_PEER"
## Frames the peer keeps playing after DONE before it closes the session.
const LINGER_FRAMES := 240
## Frames without new confirmed ticks before the match is called stuck.
const STUCK_FRAMES := 900
## Incompressible padding in the bulk probe, so it spans several
## data-channel chunks (Tuning.net.webrtc_chunk_bytes).
const PROBE_PAD_BYTES := 120000
## Two slots, one per peer.
const HUMANS := 2

enum Phase { CONNECTING, PLAYING, LINGER, OVER }

var _args := {"role": "host", "signal": "ws://127.0.0.1:18765", "code": "", "mode": "versus",
	"ticks": 1800, "seed": 7, "delay": 2, "level": 7, "enemies": 4, "timeout": 60}
var _phase := Phase.CONNECTING
var _frames := 0
var _transport: WebRtcTransport
var _session: Session
var _director: MatchDirector
var _driver: RollbackDriver
var _printed: Dictionary = {}  # checkpoint tick -> hash already printed
var _code_printed := false
var _last_confirmed := 0
var _progress_frame := 0
var _linger := 0
var _rtt_n := 0
## Guest: [tick, hash, bytes] of the host's bulk probe, until checked.
var _bulk: Array = []
var _rtt_sum := 0.0
var _rtt_max := 0.0


func _ready() -> void:
	for a in ToolArgs.pairs():
		var kv := a.split("=", true, 1)
		if kv.size() != 2 or not _args.has(kv[0]):
			continue
		_args[kv[0]] = int(kv[1]) if _args[kv[0]] is int else kv[1]
	if not OS.has_feature("web") and Engine.max_fps == 0:
		Engine.max_fps = 2 * Engine.physics_ticks_per_second  # headless: don't spin
	var host: bool = _args["role"] == "host"
	_out("START role=%s platform=%s mode=%s ticks=%d seed=%d delay=%d game=%s" % [
		_args["role"], PlatformCaps.platform_name(), _args["mode"], _args["ticks"], _args["seed"],
		_args["delay"], Net.game_id()])
	if not WebRtcTransport.available():
		_finish(false, "WebRTC unavailable")
		return
	var sig := SignalingClient.new()
	if sig.connect_to_url(str(_args["signal"])) != OK:
		_finish(false, "bad signal url %s" % _args["signal"])
		return
	_transport = WebRtcTransport.new()
	var err: Error
	if host:
		err = _transport.host_room(sig, Net.game_id(), HUMANS - 1)
		_session = Session.create_host(_transport, "Host")
	else:
		err = _transport.join_room(sig, str(_args["code"]), Net.game_id())
		_session = Session.create_guest(_transport, "Guest")
	if err != OK:
		_finish(false, "transport error %d" % err)
		return
	_session.rtt_updated.connect(func(_p: int, ms: float) -> void:
		_rtt_n += 1
		_rtt_sum += ms
		_rtt_max = maxf(_rtt_max, ms))
	_session.session_ended.connect(func(r: int) -> void:
		if _phase == Phase.CONNECTING or _phase == Phase.PLAYING:
			_finish(false, "session ended reason=%d (%s)" % [r, _transport.last_error_text()]))


func _physics_process(_delta: float) -> void:
	_frames += 1
	match _phase:
		Phase.CONNECTING:
			_connecting()
		Phase.PLAYING:
			_playing()
		Phase.LINGER:
			_driver.advance()
			_check_bulk()
			_linger += 1
			if _linger >= LINGER_FRAMES:
				_quit()


func _connecting() -> void:
	_session.update()
	if _phase != Phase.CONNECTING:
		return
	if _session.is_host():
		if not _code_printed and not _transport.room_code().is_empty():
			_code_printed = true
			_out("CODE %s" % _transport.room_code())
		if _session.peer_ids().size() >= HUMANS:
			_start()
	elif _session.state == Session.State.CONNECTED:
		_start()
	if _phase == Phase.CONNECTING and _frames > int(_args["timeout"]) * Engine.physics_ticks_per_second:
		_finish(false, "connect timeout (%s)" % _transport.last_error_text())


func _config() -> MatchConfig:
	var coop: bool = _args["mode"] == "coop"
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP if coop else MatchConfig.Mode.ONLINE)
	cfg.rng_seed = _args["seed"]
	cfg.round_time_seconds = 0
	cfg.rounds_to_win = MatchConfig.MAX_ROUNDS_TO_WIN  # rounds restart; keep going
	if coop:
		cfg.coop = CoopConfig.new()
		cfg.coop.structure = CoopConfig.Structure.BRAWL
		cfg.coop.enemy_count = Tuning.coop.max_enemy_count  # deep queue: the field stays full
	var ids := CharacterRegistry.IDS
	for i in HUMANS:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = ids[i % ids.size()]
		p.owner_peer = Transport.HOST_PEER + i
		p.display_name = "P%d" % i
		cfg.players.append(p)
	cfg.apply_platform_caps(_session.includes_platform(Protocol.PLATFORM_WEB))
	return cfg


func _start() -> void:
	var cfg := _config()
	_director = MatchDirector.new()
	add_child(_director)
	_driver = RollbackDriver.new()
	_driver.auto_run = false
	add_child(_driver)
	var local := {}
	for p in cfg.players:
		if p.owner_peer == _session.local_peer_id:
			local[p.slot] = CpuInput.new(_args["level"])
	_driver.start(_director, _session, MatchConfig.from_dict(cfg.to_dict()), local, _args["delay"])
	for slot: int in local:
		(local[slot] as CpuInput).attach(_director, slot)
	_driver.aborted.connect(func(reason: StringName) -> void:
		if _phase == Phase.PLAYING:
			_finish(false, "driver aborted %s" % reason))
	_phase = Phase.PLAYING
	_progress_frame = _frames
	_out("MATCH peer=%d peers=%s platforms=%s/%s rollback_window=%d field_cap=%d frame=%d" % [
		_session.local_peer_id, str(_session.peer_ids()), _session.peer_platform(1),
		_session.peer_platform(2), _driver.max_rollback_frames, cfg.online_field_cap, _frames])
	_out("CHANNELS %s" % _channel_info())
	_session.snapshot_received.connect(_on_bulk)


## What the data channels really got (the option keys reach the browser's
## createDataChannel): id / negotiated / ordered / maxRetransmits per channel.
func _channel_info() -> String:
	var link: Variant = _transport._links.get(_other())
	if link == null:
		return "no link"
	var parts: PackedStringArray = []
	for ch: WebRTCDataChannel in link.channels:
		parts.append("%s:id=%d,negotiated=%s,ordered=%s,max_retransmits=%d" % [
			ch.get_label(), ch.get_id(), ch.is_negotiated(), ch.is_ordered(), ch.get_max_retransmits()])
	return " ".join(parts)


func _other() -> int:
	return Transport.HOST_PEER if _session == null or not _session.is_host() else Transport.FIRST_GUEST_PEER


## Host, at DONE: its newest confirmed checkpoint as a SNAPSHOT (the drop-in
## message: BULK channel, chunked; the driver ignores it) to the guest,
## which checks it against its own checkpoint once it has confirmed it.
func _send_bulk_probe() -> void:
	var t := -1
	for k: int in _driver._checkpoints:
		if k <= int(_args["ticks"]) and _printed.has(k):
			t = maxi(t, k)
	if t < 0:
		return
	var snap: Dictionary = _driver._checkpoints[t]
	var rng := RandomNumberGenerator.new()
	rng.seed = t
	var pad := PackedByteArray()
	pad.resize(PROBE_PAD_BYTES)
	for i in PROBE_PAD_BYTES:
		pad[i] = rng.randi() & 0xFF
	var extra := {"pad": pad, "pad_hash": hash(pad)}
	var ok := _session.send_snapshot(_other(), t, snap, extra)
	var link: Variant = _transport._links.get(_other())
	var buffered: int = (link.channels[Transport.Channel.BULK] as WebRTCDataChannel).get_buffered_amount() if link != null else -1
	_out("BULK_SENT %d %d bytes=%d sent=%s buffered_after_send=%d" % [
		t, StateHash.of_state(snap), Protocol.encode_snapshot(t, snap, extra).size(), ok, buffered])


func _on_bulk(tick: int, snapshot: Dictionary, extra: Dictionary) -> void:
	var pad: Variant = extra.get("pad")
	var pad_ok: bool = pad is PackedByteArray and hash(pad) == extra.get("pad_hash")
	_bulk = [tick, StateHash.of_state(snapshot), Protocol.encode_snapshot(tick, snapshot, extra).size(), pad_ok]


## Guest: the host's snapshot, once this peer confirmed that tick itself.
func _check_bulk() -> void:
	if _bulk.is_empty() or not _printed.has(_bulk[0]):
		return
	_out("BULK %d %d bytes=%d match=%s" % [_bulk[0], _bulk[1], _bulk[2],
		_printed[_bulk[0]] == _bulk[1] and _bulk[3]])
	_bulk = []


func _playing() -> void:
	_driver.advance()
	if _phase != Phase.PLAYING:
		return
	var ticks: Array = _driver.confirmed_hashes.keys()
	ticks.sort()
	for t: int in ticks:
		if t <= int(_args["ticks"]) and not _printed.has(t):
			_printed[t] = _driver.confirmed_hashes[t]
			_out("HASH %d %d" % [t, _driver.confirmed_hashes[t]])
	_check_bulk()
	if _driver.confirmed_tick > _last_confirmed:
		_last_confirmed = _driver.confirmed_tick
		_progress_frame = _frames
	if _driver.confirmed_tick >= int(_args["ticks"]):
		_finish(_driver.resyncs == 0 and not _printed.is_empty(), "")
	elif _frames - _progress_frame > STUCK_FRAMES:
		_finish(false, "stuck at confirmed tick %d (waiting for %s)" % [_driver.confirmed_tick, _driver.waiting_for()])


func _finish(ok: bool, why: String) -> void:
	if _phase == Phase.LINGER or _phase == Phase.OVER:
		return
	var other := _other()
	var stats := "role=%s platform=%s" % [_args["role"], PlatformCaps.platform_name()]
	if _driver != null:
		stats += " confirmed=%d tick=%d hashes=%d rollbacks=%d rollback_ticks=%d stall_frames=%d resyncs=%d phase=%d" % [
			_driver.confirmed_tick, _director.tick, _printed.size(), _driver.rollbacks,
			_driver.rollback_ticks, _driver.stall_frames, _driver.resyncs, _director.phase]
	if _session != null:
		stats += " rtt_ms=%.1f rtt_mean=%.1f rtt_max=%.1f rtt_samples=%d" % [
			_session.rtt_ms(other), _rtt_sum / maxi(_rtt_n, 1), _rtt_max, _rtt_n]
	stats += " frames=%d" % _frames
	_out("DONE %s %s%s" % ["OK" if ok else "FAIL", stats, "" if why.is_empty() else " why=" + why])
	if ok and _driver != null:
		_phase = Phase.LINGER
		if _session.is_host():
			_send_bulk_probe()
	else:
		_quit(1)


func _quit(code: int = 0) -> void:
	_phase = Phase.OVER
	if _session != null:
		_session.close()
	get_tree().quit(code)


func _out(s: String) -> void:
	print("%s %s" % [PREFIX, s])
