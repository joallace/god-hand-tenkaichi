extends Node
## Protocol encode/decode (SPEC_ONLINE.md §5): every message round-trips;
## truncated, trailing, oversize, garbage, wrong-channel and out-of-range
## packets are rejected; bulk zstd round-trip and size cap; host-only
## messages from non-hosts are ignored by sessions on both sides.
## Run as a scene:  godot --headless res://tests/net_protocol_test.tscn

const T := Protocol.Type
const CH_U := Transport.Channel.UNRELIABLE
const CH_R := Transport.Channel.RELIABLE
const CH_B := Transport.Channel.BULK

var _failures := 0
var _signals: Array[String] = []


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_hot_round_trips, _test_reliable_round_trips, _test_bulk,
		_test_malformed, _test_host_only_table, _test_session_ignores_non_host,
	]
	for t in tests:
		t.call()
	print("NET PROTOCOL TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _frame(seed_value: int) -> InputFrame:
	var f := InputFrame.new()
	f.move_x = (seed_value * 37) % 255 - 127
	f.move_y = -((seed_value * 11) % 127)
	f.held = (seed_value * 2654435761) & 0x1FFF & ~InputFrame.Btn.PAUSE
	f.dodge = (seed_value % 5) as InputFrame.Dodge
	f.target_request = seed_value % 4 - 1
	return f


func _frames(start: int, n: int) -> Array[InputFrame]:
	var out: Array[InputFrame] = []
	for i in n:
		out.append(_frame(start + i))
	return out


func _test_hot_round_trips() -> void:
	var slots := [
		{"slot": 0, "first_tick": 4000000000, "frames": _frames(1, 14)},
		{"slot": 3, "first_tick": 1, "frames": _frames(50, 1)},
	]
	var b := Protocol.encode_input(7, 123456, slots)
	_check(b.size() == Protocol.INPUT_HEADER + 2 * Protocol.INPUT_SLOT_HEADER + 15 * InputFrame.WIRE_SIZE,
		"INPUT size matches the fixed layout")
	var m := Protocol.decode(b, CH_U)
	var ok: bool = m.get("type") == T.INPUT and m["origin"] == 7 and m["ack"] == 123456 and m["slots"].size() == 2
	if ok:
		for i in 2:
			var src: Dictionary = slots[i]
			var dst: Dictionary = m["slots"][i]
			ok = ok and dst["slot"] == src["slot"] and dst["first_tick"] == src["first_tick"]
			for k in (src["frames"] as Array).size():
				ok = ok and (dst["frames"][k] as InputFrame).equals(src["frames"][k])
	_check(ok, "INPUT round-trips origin, ack, slots, ticks and frames")

	m = Protocol.decode(Protocol.encode_input_ack(3, {1: 10, 2: 4294967295, 9: 0}), CH_U)
	_check(m.get("type") == T.INPUT_ACK and m["sender"] == 3 and m["acks"] == {1: 10, 2: 4294967295, 9: 0},
		"INPUT_ACK round-trips")
	m = Protocol.decode(Protocol.encode_ping(2, 99999, 77), CH_U)
	_check(m.get("type") == T.PING and m["sender"] == 2 and m["time_ms"] == 99999 and m["tick"] == 77, "PING round-trips")
	m = Protocol.decode(Protocol.encode_pong(1, 5, 8), CH_U)
	_check(m.get("type") == T.PONG and m["sender"] == 1 and m["echo_time_ms"] == 5 and m["tick"] == 8, "PONG round-trips")
	m = Protocol.decode(Protocol.encode_hash(4, 300, -1234567890123), CH_U)
	_check(m.get("type") == T.HASH and m["sender"] == 4 and m["tick"] == 300 and m["hash"] == -1234567890123,
		"HASH round-trips a signed 64-bit hash")


func _test_reliable_round_trips() -> void:
	var hello := {"engine_version": 0x040702, "game_build": "dev", "content_hash": "abc123", "name": "Joe"}
	var m := Protocol.decode(Protocol.encode_hello(hello), CH_R)
	_check(m.get("type") == T.HELLO and m["name"] == "Joe" and m["content_hash"] == "abc123"
		and m["protocol_version"] == Protocol.PROTOCOL_VERSION and m["reconnect_token"] == "",
		"HELLO round-trips (protocol version and empty token filled in)")
	m = Protocol.decode(Protocol.encode_welcome(3, "tok", {"mode": 1}, {1: "Host", 3: "Joe"}), CH_R)
	_check(m.get("type") == T.WELCOME and m["peer_id"] == 3 and m["reconnect_token"] == "tok"
		and m["lobby"] == {"mode": 1} and m["peers"] == {1: "Host", 3: "Joe"}, "WELCOME round-trips")
	m = Protocol.decode(Protocol.encode_reject(Protocol.Reason.VERSION, "4.7.2 vs 4.7.1"), CH_R)
	_check(m.get("type") == T.REJECT and m["reason"] == Protocol.Reason.VERSION and m["detail"] == "4.7.2 vs 4.7.1",
		"REJECT round-trips")
	m = Protocol.decode(Protocol.encode_lobby_state({"slots": [1, 2], "rules": {"rounds": 3}}), CH_R)
	_check(m.get("type") == T.LOBBY_STATE and m["lobby"]["rules"]["rounds"] == 3, "LOBBY_STATE round-trips")
	m = Protocol.decode(Protocol.encode_peers({1: "A", 2: "B"}), CH_R)
	_check(m.get("type") == T.PEERS and m["peers"] == {1: "A", 2: "B"}, "PEERS round-trips")
	m = Protocol.decode(Protocol.encode_match_start({"mode": 2}, 42, {"delay": 2}), CH_R)
	_check(m.get("type") == T.MATCH_START and m["config"] == {"mode": 2} and m["seed"] == 42 and m["start"] == {"delay": 2},
		"MATCH_START round-trips")
	m = Protocol.decode(Protocol.encode_cmd({"tick": 500, "kind": 1, "slot": 2}), CH_R)
	_check(m.get("type") == T.CMD and m["cmd"] == {"tick": 500, "kind": 1, "slot": 2}, "CMD round-trips")
	m = Protocol.decode(Protocol.encode_drop(3, 400, Protocol.Reason.TIMEOUT), CH_R)
	_check(m.get("type") == T.DROP and m["peer"] == 3 and m["last_tick"] == 400 and m["reason"] == Protocol.Reason.TIMEOUT,
		"DROP round-trips")
	m = Protocol.decode(Protocol.encode_bye(Protocol.Reason.HOST_CLOSING), CH_R)
	_check(m.get("type") == T.BYE and m["reason"] == Protocol.Reason.HOST_CLOSING, "BYE round-trips")


func _big_snapshot(n: int) -> Dictionary:
	var fighters := []
	for i in n:
		fighters.append({"pos": Vector3(i, 0.5, -i), "hp": 1000 - i, "state": "IDLE", "flags": PackedInt32Array([i, i * 2])})
	return {"tick": 1234, "fighters": fighters, "rng": 987654321}


func _test_bulk() -> void:
	var snap := _big_snapshot(2000)
	var b := Protocol.encode_resync(1234, snap)
	_check(not b.is_empty() and b.size() < var_to_bytes(snap).size(), "RESYNC is zstd-compressed")
	var m := Protocol.decode(b, CH_B)
	_check(m.get("type") == T.RESYNC and m["tick"] == 1234 and m["snapshot"] == snap, "RESYNC round-trips a snapshot")
	m = Protocol.decode(Protocol.encode_snapshot(77, snap, {"inputs": {0: PackedByteArray([1, 2])}}), CH_B)
	_check(m.get("type") == T.SNAPSHOT and m["snapshot"] == snap and m["extra"]["inputs"][0] == PackedByteArray([1, 2]),
		"SNAPSHOT round-trips with extra")

	var max_bulk := Tuning.net.max_bulk_bytes
	Tuning.net.max_bulk_bytes = 1024
	_check(Protocol.encode_resync(1, snap).is_empty(), "encoder refuses a snapshot over max_bulk_bytes")
	Tuning.net.max_bulk_bytes = max_bulk
	# A zip bomb: tiny compressed payload claiming/expanding past the cap.
	var bomb_raw := var_to_bytes({"tick": 1, "snapshot": {"pad": "x".repeat(200000)}})
	var bomb := PackedByteArray([T.RESYNC, 0, 0, 0, 0])
	bomb.encode_u32(1, bomb_raw.size())
	bomb.append_array(bomb_raw.compress(FileAccess.COMPRESSION_ZSTD))
	_check(not Protocol.decode(bomb, CH_B).is_empty(), "control: honest header decodes")
	Tuning.net.max_bulk_bytes = 100000
	_check(bomb.size() < 100000 and Protocol.decode(bomb, CH_B).is_empty(), "decoder refuses raw size over max_bulk_bytes")
	Tuning.net.max_bulk_bytes = max_bulk
	var liar := bomb.duplicate()
	liar.encode_u32(1, 1000)
	_check(Protocol.decode(liar, CH_B).is_empty(), "decompressed size must match the header")
	var junk := PackedByteArray([T.SNAPSHOT, 100, 0, 0, 0, 1, 2, 3, 4, 5, 6])
	_check(Protocol.decode(junk, CH_B).is_empty(), "garbage zstd rejected")
	var not_dict := PackedByteArray([T.RESYNC, 0, 0, 0, 0])
	var arr := var_to_bytes([1, 2, 3])
	not_dict.encode_u32(1, arr.size())
	not_dict.append_array(arr.compress(FileAccess.COMPRESSION_ZSTD))
	_check(Protocol.decode(not_dict, CH_B).is_empty(), "bulk payload must be a Dictionary")


func _test_malformed() -> void:
	var input := Protocol.encode_input(2, 5, [{"slot": 1, "first_tick": 10, "frames": _frames(1, 3)}])
	var all_ok := true
	for n in input.size():
		all_ok = all_ok and Protocol.decode(input.slice(0, n), CH_U).is_empty()
	_check(all_ok, "every truncation of INPUT is rejected")
	var trailing := input.duplicate()
	trailing.append(0)
	_check(Protocol.decode(trailing, CH_U).is_empty(), "INPUT with trailing bytes rejected")
	_check(Protocol.decode(input, CH_R).is_empty(), "INPUT on the reliable channel rejected")
	var zero := input.duplicate()
	zero.encode_u8(Protocol.INPUT_HEADER + Protocol.COUNT_BYTES + Protocol.TICK_BYTES, 0)
	_check(Protocol.decode(zero, CH_U).is_empty(), "INPUT slot with zero frames rejected")
	var bad_origin := input.duplicate()
	bad_origin.encode_u8(1, 0)
	_check(Protocol.decode(bad_origin, CH_U).is_empty(), "INPUT from peer 0 rejected")
	var dup_slots := Protocol.encode_input(2, 5, [
		{"slot": 1, "first_tick": 10, "frames": _frames(1, 1)},
		{"slot": 1, "first_tick": 10, "frames": _frames(1, 1)}])
	_check(Protocol.decode(dup_slots, CH_U).is_empty(), "INPUT with a repeated slot rejected")
	var wrap := Protocol.encode_input(2, 5, [{"slot": 0, "first_tick": Protocol.U32_MAX, "frames": _frames(1, 1)}])
	wrap.encode_u8(Protocol.INPUT_HEADER + Protocol.COUNT_BYTES + Protocol.TICK_BYTES, 2)
	wrap.append_array(_frame(3).to_bytes())
	_check(Protocol.decode(wrap, CH_U).is_empty(), "INPUT ticks past u32 rejected")
	_check(Protocol.encode_input(2, 5, [{"slot": 0, "first_tick": 1, "frames": _frames(1, 256)}]).is_empty(),
		"encoder refuses more than 255 frames per slot")
	_check(Protocol.encode_input(0, 5, [{"slot": 0, "first_tick": 1, "frames": _frames(1, 1)}]).is_empty(),
		"encoder refuses peer 0")
	_check(Protocol.encode_input(2, -1, [{"slot": 0, "first_tick": 1, "frames": _frames(1, 1)}]).is_empty(),
		"encoder refuses negative ticks")

	var big := PackedByteArray()
	big.resize(Tuning.net.max_packet_bytes + 1)
	big.encode_u8(0, T.LOBBY_STATE)
	_check(Protocol.decode(big, CH_R).is_empty(), "packet over max_packet_bytes rejected")
	_check(Protocol.encode_lobby_state({"pad": "x".repeat(Tuning.net.max_packet_bytes)}).is_empty(),
		"encoder refuses a reliable message over max_packet_bytes")
	_check(Protocol.decode(PackedByteArray(), CH_U).is_empty(), "empty packet rejected")
	_check(Protocol.decode(PackedByteArray([200, 1, 2, 3]), CH_U).is_empty(), "unknown type rejected")
	_check(Protocol.decode(Protocol.encode_ping(1, 1, 1).slice(0, Protocol.PING_SIZE - 1), CH_U).is_empty(),
		"truncated PING rejected")
	var ack := Protocol.encode_input_ack(2, {1: 5, 3: 6})
	ack.encode_u8(2, 3)
	_check(Protocol.decode(ack, CH_U).is_empty(), "INPUT_ACK count/length mismatch rejected")
	_check(Protocol.decode(Protocol.encode_hash(2, 1, 1), CH_R).is_empty(), "HASH on the wrong channel rejected")

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var garbage_ok := true
	for i in 300:
		var g := PackedByteArray()
		g.resize(rng.randi_range(1, 64))
		for k in g.size():
			g[k] = rng.randi() & 0xFF
		var ch := rng.randi_range(0, 2)
		g[0] = [T.INPUT, T.INPUT_ACK, T.PING, T.HASH][rng.randi() % 4] if ch == CH_U else g[0]
		var m := Protocol.decode(g, ch)
		if not m.is_empty() and m["type"] == T.INPUT:
			garbage_ok = garbage_ok and (m["slots"] as Array).size() >= 1
	_check(garbage_ok, "random garbage never decodes into an invalid message")

	var reliable_garbage := PackedByteArray([T.HELLO])
	reliable_garbage.append_array(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	_check(Protocol.decode(reliable_garbage, CH_R).is_empty(), "garbage reliable payload rejected")
	var wrong_kind := PackedByteArray([T.HELLO])
	wrong_kind.append_array(var_to_bytes([1, 2]))
	_check(Protocol.decode(wrong_kind, CH_R).is_empty(), "reliable payload that isn't a Dictionary rejected")
	var mistyped := PackedByteArray([T.HELLO])
	mistyped.append_array(var_to_bytes({"protocol_version": "1", "engine_version": 1, "game_build": "dev",
		"content_hash": "", "name": "x", "reconnect_token": ""}))
	_check(Protocol.decode(mistyped, CH_R).is_empty(), "HELLO with a mistyped field rejected")
	var missing := PackedByteArray([T.CMD])
	missing.append_array(var_to_bytes({"cmd": {"kind": 1}}))
	_check(Protocol.decode(missing, CH_R).is_empty(), "CMD without a tick rejected")
	var with_object := PackedByteArray([T.LOBBY_STATE])
	with_object.append_array(var_to_bytes_with_objects({"lobby": {"o": InputFrame.new()}}))
	_check(Protocol.decode(with_object, CH_R).is_empty(), "payload carrying an Object rejected")
	var bad_peers := PackedByteArray([T.PEERS])
	bad_peers.append_array(var_to_bytes({"peers": {"one": "A"}}))
	_check(Protocol.decode(bad_peers, CH_R).is_empty(), "PEERS with a non-int id rejected")
	var tail := Protocol.encode_bye(Protocol.Reason.LEFT)
	tail.append_array(PackedByteArray([0, 0, 0, 0]))
	_check(Protocol.decode(tail, CH_R).is_empty(), "reliable message with trailing bytes rejected")


func _test_host_only_table() -> void:
	var host_only := [T.WELCOME, T.REJECT, T.LOBBY_STATE, T.PEERS, T.MATCH_START, T.CMD, T.DROP, T.RESYNC, T.SNAPSHOT]
	var ok := true
	for t: int in Protocol.Type.values():
		ok = ok and Protocol.is_host_only(t) == host_only.has(t)
	_check(ok, "is_host_only covers lobby, start, commands, drop, snapshots and handshake replies")


# --- sessions ignore host-only messages from non-hosts ---------------------------

func _record(name: String) -> Callable:
	return func(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void: _signals.append(name)


func _watch(s: Session) -> void:
	s.lobby_state_received.connect(_record("lobby"))
	s.command_received.connect(_record("cmd"))
	s.snapshot_received.connect(_record("snapshot"))
	s.resync_received.connect(_record("resync"))
	s.match_start_received.connect(_record("start"))
	s.peers_changed.connect(_record("peers"))


func _pump(net: LoopbackNetwork, sessions: Array, frames: int) -> void:
	for i in frames:
		net.advance_frame()
		for s: Session in sessions:
			s.update()


func _host_only_messages() -> Array[PackedByteArray]:
	return [
		Protocol.encode_lobby_state({"evil": true}),
		Protocol.encode_cmd({"tick": 5, "kind": 1}),
		Protocol.encode_match_start({}, 1),
		Protocol.encode_peers({1: "x"}),
		Protocol.encode_snapshot(1, {"evil": true}),
		Protocol.encode_resync(1, {"evil": true}),
	]


func _test_session_ignores_non_host() -> void:
	var net := LoopbackNetwork.new(1)
	var ht := net.create_host()
	var gt := net.create_client()
	var host := Session.create_host(ht, "Host")
	var guest := Session.create_guest(gt, "Guest")
	net.connect_client(gt, ht)
	_pump(net, [host, guest], 5)
	if not _check(guest.state == Session.State.CONNECTED, "guest connected"):
		return

	# A rogue endpoint linked straight to the guest (not the host link).
	var rogue := net.create_client()
	net.link(gt, rogue, 9, 1)
	_pump(net, [host, guest], 2)
	_signals.clear()
	_watch(guest)
	var dropped := guest.dropped_packets
	for b in _host_only_messages():
		rogue.send(1, Protocol.channel_of(b[0]), b)
	_pump(net, [host, guest], 3)
	_check(_signals.is_empty() and guest.dropped_packets >= dropped + _host_only_messages().size(),
		"guest ignores lobby/cmd/snapshot messages from a non-host link")

	# The guest itself sending host-only messages to the host.
	_signals.clear()
	_watch(host)
	dropped = host.dropped_packets
	for b in _host_only_messages():
		gt.send(Transport.HOST_PEER, Protocol.channel_of(b[0]), b)
	_pump(net, [host, guest], 3)
	_check(_signals.is_empty() and host.dropped_packets == dropped + _host_only_messages().size(),
		"host ignores lobby/cmd/snapshot messages from a guest")
	_check(host.lobby_state.is_empty(), "host lobby state untouched")

	# The real host's messages do reach the guest.
	_signals.clear()
	host.set_lobby_state({"mode": 1})
	host.send_command({"tick": 9, "kind": 2})
	_pump(net, [host, guest], 3)
	_check(_signals.has("lobby") and _signals.has("cmd") and guest.lobby_state == {"mode": 1},
		"host's own lobby state and commands reach the guest")
