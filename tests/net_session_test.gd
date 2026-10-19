extends Node
## Session over LoopbackTransport (SPEC_ONLINE.md §5, §13): handshake and
## rejects, host-relayed input delivery for 2 and 4 peers under latency,
## jitter and loss (redundancy fills every gap), acks, RTT, TimeSync,
## mispredictions, and disconnect detection (silence, BYE, link loss).
## Run as a scene:  godot --headless res://tests/net_session_test.tscn

const Reason := Protocol.Reason
## Ticks of scripted input per run.
const TICKS := 240
## Frames run after the last input so redundancy can drain.
const DRAIN := 120

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_handshake, _test_rejects,
		_test_delivery.bind(2, 0.0, 0.0, 0.0), _test_delivery.bind(2, 50.0, 10.0, 5.0),
		_test_delivery.bind(2, 150.0, 30.0, 10.0), _test_delivery.bind(4, 0.0, 0.0, 0.0),
		_test_delivery.bind(4, 80.0, 20.0, 5.0), _test_delivery.bind(4, 150.0, 30.0, 10.0),
		_test_time_sync, _test_mispredictions, _test_silent_guest, _test_silent_host,
		_test_graceful_leave, _test_link_loss,
	]
	for t in tests:
		t.call()
	print("NET SESSION TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- harness ------------------------------------------------------------------

## Deterministic, busy input for a slot at a tick.
static func _gen(slot: int, tick: int) -> InputFrame:
	var f := InputFrame.new()
	f.move_x = ((tick / 7 + slot * 13) % 255) - 127
	f.move_y = ((tick / 5 + slot * 29) % 255) - 127
	f.held = ((tick / 11 + slot) * 37) & 0x1FFF & ~InputFrame.Btn.PAUSE
	f.dodge = ((tick / 17 + slot) % 5) as InputFrame.Dodge if tick % 17 == 0 else InputFrame.Dodge.NONE
	f.target_request = (tick / 50 + slot) % 4 - 1
	return f


## Host + n-1 guests on a fresh network; returns [net, sessions...].
func _room(n: int, latency: float = 0.0, jitter: float = 0.0, loss: float = 0.0, seed_value: int = 1) -> Array:
	var net := LoopbackNetwork.new(seed_value)
	net.latency_ms = latency
	net.jitter_ms = jitter
	net.loss_percent = loss
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host")
	host.clock = net.now_ms
	var out: Array = [net, host]
	for i in n - 1:
		var gt := net.create_client()
		var g := Session.create_guest(gt, "Guest%d" % (i + 1))
		g.clock = net.now_ms
		net.connect_client(gt, ht)
		out.append(g)
	return out


func _pump(net: LoopbackNetwork, sessions: Array, frames: int, before_send: Callable = Callable()) -> void:
	for i in frames:
		net.advance_frame()
		for s: Session in sessions:
			s.receive()
			if before_send.is_valid():
				before_send.call(s)
			s.send_pending()


## Pump until every guest is welcomed (or give up).
func _connect_all(net: LoopbackNetwork, sessions: Array) -> bool:
	for i in 300:
		_pump(net, sessions, 1)
		var all := true
		for s: Session in sessions:
			all = all and s.state == Session.State.CONNECTED
		if all:
			return true
	return false


## slot i owned by session i.
func _owners(sessions: Array) -> Dictionary:
	var owners := {}
	for i in sessions.size():
		owners[i] = (sessions[i] as Session).local_peer_id
	return owners


# --- tests --------------------------------------------------------------------

func _test_handshake() -> void:
	var r := _room(3)
	var net: LoopbackNetwork = r[0]
	var sessions := r.slice(1)
	var host: Session = sessions[0]
	host.set_lobby_state({"mode": 1})
	var joined := []
	host.peer_joined.connect(func(p: int, nm: String) -> void: joined.append([p, nm]))
	var lobby_seen := []
	(sessions[2] as Session).lobby_state_received.connect(func(l: Dictionary) -> void: lobby_seen.append(l))
	if not _check(_connect_all(net, sessions), "3 peers: every guest welcomed"):
		return
	var g1: Session = sessions[1]
	var g2: Session = sessions[2]
	_check(g1.local_peer_id == 2 and g2.local_peer_id == 3, "guests get ids 2 and 3 from the host")
	_check(joined.size() == 2 and joined[0][1] == "Guest1", "host sees peer_joined with names")
	_check(host.peer_ids() == [1, 2, 3] and g1.peer_ids() == [1, 2, 3] and g2.peer_ids() == [1, 2, 3],
		"everyone has the full peer table")
	_check(g1.peer_name(3) == "Guest2" and g2.peer_name(1) == "Host", "names propagate (PEERS)")
	_check(lobby_seen.size() == 1 and lobby_seen[0] == {"mode": 1}, "WELCOME carries the lobby state")
	_check(not g1.reconnect_token.is_empty() and g1.reconnect_token != g2.reconnect_token,
		"each guest gets its own reconnect token")
	host.set_lobby_state({"mode": 2})
	_pump(net, sessions, 3)
	_check(g1.lobby_state == {"mode": 2} and lobby_seen.size() == 2, "lobby updates reach guests")
	var starts := []
	g2.match_start_received.connect(func(c: Dictionary, s: int, st: Dictionary) -> void: starts.append([c, s, st]))
	var cmds := []
	g1.command_received.connect(func(c: Dictionary) -> void: cmds.append(c))
	host.start_match({"rounds": 3}, 99, {"delay": 2})
	host.send_command({"tick": 10, "kind": 1, "slot": 1})
	_pump(net, sessions, 3)
	_check(starts.size() == 1 and starts[0][1] == 99 and starts[0][0] == {"rounds": 3}, "MATCH_START reaches guests")
	_check(cmds.size() == 1 and cmds[0]["slot"] == 1, "CMD reaches guests")
	_check(not g1.send_command({"tick": 1, "kind": 1}) and not g1.start_match({}, 1), "guests can't send host messages")
	var hashes := []
	host.hash_received.connect(func(p: int, t: int, h: int) -> void: hashes.append([p, t, h]))
	g2.send_hash(30, -77)
	var snaps := []
	g1.resync_received.connect(func(t: int, s: Dictionary) -> void: snaps.append([t, s]))
	host.send_resync(2, 30, {"state": [1, 2, 3]})
	_pump(net, sessions, 3)
	_check(hashes == [[3, 30, -77]], "HASH reaches the host tagged with its sender")
	_check(snaps.size() == 1 and snaps[0][0] == 30 and snaps[0][1] == {"state": [1, 2, 3]}, "RESYNC reaches its guest")


func _reject_case(ident: Dictionary, label: String, expect: int, setup: Callable = Callable(),
		guest_name: String = "Guest") -> void:
	var net := LoopbackNetwork.new(3)
	net.latency_ms = 30.0
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host", {"content_hash": "abc"})
	if setup.is_valid():
		setup.call(host)
	var sessions: Array = [host]
	var extra := 0
	if expect == Reason.ROOM_FULL:
		var first_t := net.create_client()
		var first := Session.create_guest(first_t, "First", {"content_hash": "abc"})
		net.connect_client(first_t, ht)
		sessions.append(first)
		_pump(net, sessions, 10)
		extra = 1
	var gt := net.create_client()
	var g := Session.create_guest(gt, guest_name, ident)
	net.connect_client(gt, ht)
	sessions.append(g)
	var got := []
	g.rejected.connect(func(r: int, d: String) -> void: got.append([r, d]))
	var ended := []
	g.session_ended.connect(func(r: int) -> void: ended.append(r))
	_pump(net, sessions, 30)
	_check(got.size() == 1 and got[0][0] == expect and ended == [expect] and g.state == Session.State.CLOSED,
		"%s -> REJECT (%s)" % [label, got[0][1] if not got.is_empty() else "none"])
	_check(host.link_peers().size() == extra and host.peer_ids().size() == 1 + extra, "%s: host keeps no peer" % label)


func _test_rejects() -> void:
	_reject_case({"engine_version": 0x030500, "content_hash": "abc"}, "engine version mismatch", Reason.VERSION)
	_reject_case({"game_build": "1.2", "content_hash": "abc"}, "game build mismatch", Reason.VERSION)
	_reject_case({"protocol_version": Protocol.PROTOCOL_VERSION + 1, "content_hash": "abc"},
		"protocol mismatch", Reason.VERSION)
	_reject_case({"content_hash": "zzz"}, "content hash mismatch", Reason.CONTENT)
	_reject_case({"content_hash": "abc"}, "match in progress", Reason.IN_PROGRESS,
		func(h: Session) -> void: h.accepting_joins = false)
	_reject_case({"content_hash": "abc"}, "room full", Reason.ROOM_FULL,
		func(h: Session) -> void: h.max_guests = 1)
	_reject_case({"content_hash": "abc"}, "bad name", Reason.BAD_NAME, Callable(), "bad\nname")
	_reject_case({"content_hash": "abc"}, "long name", Reason.BAD_NAME, Callable(),
		"x".repeat(Tuning.net.name_max_len + 1))


func _test_delivery(n: int, latency: float, jitter: float, loss: float) -> void:
	var label := "%d peers, %d ms +%d jitter, %d%% loss" % [n, latency, jitter, loss]
	var r := _room(n, latency, jitter, loss, n * 100 + int(latency))
	var net: LoopbackNetwork = r[0]
	var sessions := r.slice(1)
	if not _check(_connect_all(net, sessions), "%s: connected" % label):
		return
	var owners := _owners(sessions)
	var received := {}
	for s: Session in sessions:
		s.begin_match(owners)
		var id := s.local_peer_id
		received[id] = 0
		s.input_received.connect(func(_o: int, _sl: int, _t: int, _f: InputFrame) -> void: received[id] += 1)
	var tick := [0]
	var submit := func(s: Session) -> void:
		s.local_tick = tick[0]
		if tick[0] >= 1 and tick[0] <= TICKS:
			for slot in s.slots_of(s.local_peer_id):
				s.submit_local_input(slot, tick[0], _gen(slot, tick[0]))
	for f in TICKS + DRAIN:
		tick[0] = f + 1
		_pump(net, sessions, 1, submit)

	var all_ok := true
	var first_bad := ""
	for i in sessions.size():
		var s: Session = sessions[i]
		for slot in owners:
			for t in range(1, TICKS + 1):
				var got := s.history.confirmed_frame(slot, t)
				if got == null or not got.equals(_gen(slot, t)):
					all_ok = false
					if first_bad.is_empty():
						first_bad = "peer %d slot %d tick %d" % [s.local_peer_id, slot, t]
	if not all_ok:
		for s: Session in sessions:
			var info := []
			for slot in owners:
				info.append([slot, s.history.last_confirmed_tick(slot), s.history.latest_tick(slot)])
			var acks := []
			for o in owners.values():
				for d in owners.values():
					acks.append("%d>%d:%d" % [o, d, s.ack(o, d)])
			print("DEBUG peer %d contig %s acks %s state %d links %s frame %d net %d inflight %d" % [s.local_peer_id, info, acks, s.state, s.link_peers(), s.frame_count(), net.frame, net.in_flight_count()])
	_check(all_ok, "%s: every peer has every slot's frames 1..%d, correct %s" % [label, TICKS, first_bad])
	var counts_ok := true
	for s: Session in sessions:
		counts_ok = counts_ok and received[s.local_peer_id] == (n - 1) * TICKS
	_check(counts_ok, "%s: input_received fires once per remote frame" % label)

	var acks_ok := true
	var host: Session = sessions[0]
	for s: Session in sessions:
		for o in owners.values():
			acks_ok = acks_ok and s.ack(o, s.local_peer_id) == TICKS
	for g: Session in sessions.slice(1):
		acks_ok = acks_ok and host.ack(g.local_peer_id, Transport.HOST_PEER) == TICKS \
			and host.ack(Transport.HOST_PEER, g.local_peer_id) == TICKS \
			and g.ack(g.local_peer_id, Transport.HOST_PEER) == TICKS
		for o in owners.values():
			if o != g.local_peer_id:
				acks_ok = acks_ok and host.ack(o, g.local_peer_id) == TICKS
	_check(acks_ok, "%s: acks reach the last tick on every link" % label)

	var frame_ms := net.frame_ms()
	var rtt_ok := true
	var rtts := []
	for g: Session in sessions.slice(1):
		for pair: Array in [[g, Transport.HOST_PEER], [host, g.local_peer_id]]:
			var rtt: float = (pair[0] as Session).rtt_ms(pair[1])
			rtts.append(roundi(rtt))
			rtt_ok = rtt_ok and rtt >= 2.0 * latency - 1.0 and rtt <= 2.0 * (latency + jitter) + 2.0 * frame_ms + 1.0
	_check(rtt_ok, "%s: RTT estimates sane %s" % [label, rtts])
	var ahead_ok := true
	for s: Session in sessions:
		for p in s.link_peers():
			ahead_ok = ahead_ok and absf(s.time_sync.advantage(p)) < 1.5
	_check(ahead_ok, "%s: peers in step show ~0 frame advantage" % label)
	_check(host.dropped_packets == 0, "%s: no packet rejected" % label)


func _test_time_sync() -> void:
	var r := _room(2, 50.0)
	var net: LoopbackNetwork = r[0]
	var host: Session = r[1]
	var guest: Session = r[2]
	if not _check(_connect_all(net, [host, guest]), "time sync: connected"):
		return
	var lead := 5
	var f := [0]
	var set_tick := func(s: Session) -> void: s.local_tick = f[0] + (lead if s == guest else 0)
	for i in Tuning.net.ping_interval_frames * 20:
		f[0] = i + 1
		_pump(net, [host, guest], 1, set_tick)
	_check(absf(guest.time_sync.advantage(1) - lead) < 1.0,
		"guest running %d ticks ahead sees ~+%d advantage (%.2f)" % [lead, lead, guest.time_sync.advantage(1)])
	_check(absf(host.time_sync.advantage(2) + lead) < 1.0, "host sees ~-%d (%.2f)" % [lead, host.time_sync.advantage(2)])
	_check(guest.time_sync.should_wait(f[0]) and not host.time_sync.should_wait(f[0]), "only the peer ahead waits")


func _test_mispredictions() -> void:
	var r := _room(2, 100.0)
	var net: LoopbackNetwork = r[0]
	var host: Session = r[1]
	var guest: Session = r[2]
	if not _check(_connect_all(net, [host, guest]), "mispredictions: connected"):
		return
	host.begin_match({0: 1})
	guest.begin_match({0: 1})
	var reported := []
	guest.mispredicted.connect(func(slot: int, t: int) -> void: reported.append([slot, t]))
	var tick := [0]
	var step := func(s: Session) -> void:
		if s == host and tick[0] <= 60:
			s.submit_local_input(0, tick[0], _gen(0, tick[0]))
		if s == guest and tick[0] <= 60:
			s.history.frame_for(0, tick[0])  # the sim runs ahead on predictions
	for i in 120:
		tick[0] = i + 1
		_pump(net, [host, guest], 1, step)
	var ok := not reported.is_empty()
	# Every reported tick really was predicted wrong (the used frame is still
	# the prediction: nothing re-simulated here).
	for e: Array in reported:
		var t: int = e[1]
		ok = ok and e[0] == 0 and not guest.history.used_frame(0, t).equals(guest.history.confirmed_frame(0, t))
	_check(ok, "late remote frames that differ from predictions fire mispredicted (%d)" % reported.size())


func _test_silent_guest() -> void:
	var r := _room(3, 40.0)
	var net: LoopbackNetwork = r[0]
	var sessions := r.slice(1)
	var host: Session = sessions[0]
	var g1: Session = sessions[1]
	var g2: Session = sessions[2]
	if not _check(_connect_all(net, sessions), "silent guest: connected"):
		return
	for s: Session in sessions:
		s.begin_match({0: 1, 1: 2, 2: 3})
	var t := [0]
	var submit := func(s: Session) -> void:
		for slot in s.slots_of(s.local_peer_id):
			s.submit_local_input(slot, t[0], _gen(slot, t[0]))
	for i in 30:
		t[0] = i + 1
		_pump(net, sessions, 1, submit)
	var left := []
	host.peer_left.connect(func(p: int, why: int, last: int) -> void: left.append([p, why, last]))
	var g1_left := []
	g1.peer_left.connect(func(p: int, why: int, last: int) -> void: g1_left.append([p, why, last]))
	net.set_silent(g2.transport as LoopbackTransport, true)
	var frames_to_drop := 0
	while left.is_empty() and frames_to_drop < Tuning.net.disconnect_timeout_frames * 2:
		frames_to_drop += 1
		_pump(net, [host, g1], 1)
	_check(left.size() == 1 and left[0][0] == 3 and left[0][1] == Reason.TIMEOUT,
		"silent guest dropped with TIMEOUT")
	_check(frames_to_drop >= Tuning.net.disconnect_timeout_frames
		and frames_to_drop <= Tuning.net.disconnect_timeout_frames + 10,
		"only after disconnect_timeout_frames (%d)" % frames_to_drop)
	_check(not left.is_empty() and left[0][2] == host.history.last_confirmed_tick(2) and left[0][2] > 20,
		"cut point = last tick of its input the host confirmed")
	_pump(net, [host, g1], 10)
	_check(g1_left.size() == 1 and g1_left[0][0] == 3 and g1_left[0][2] == left[0][2],
		"other guests hear DROP with the same cut point")
	_check(host.peer_ids() == [1, 2] and g1.peer_ids() == [1, 2], "peer tables forget the dropped guest")


func _test_silent_host() -> void:
	var r := _room(2, 20.0)
	var net: LoopbackNetwork = r[0]
	var host: Session = r[1]
	var guest: Session = r[2]
	if not _check(_connect_all(net, [host, guest]), "silent host: connected"):
		return
	var ended := []
	guest.session_ended.connect(func(why: int) -> void: ended.append(why))
	net.set_silent(host.transport as LoopbackTransport, true)
	_pump(net, [host, guest], Tuning.net.disconnect_timeout_frames + 5)
	_check(ended == [Reason.TIMEOUT] and guest.state == Session.State.CLOSED, "guest ends the session when the host goes silent")


func _test_graceful_leave() -> void:
	var r := _room(3, 30.0)
	var net: LoopbackNetwork = r[0]
	var sessions := r.slice(1)
	var host: Session = sessions[0]
	var g1: Session = sessions[1]
	var g2: Session = sessions[2]
	if not _check(_connect_all(net, sessions), "leave: connected"):
		return
	var left := []
	host.peer_left.connect(func(p: int, why: int, _last: int) -> void: left.append([p, why]))
	g2.close()
	_pump(net, [host, g1], 10)
	_check(left == [[3, Reason.LEFT]], "a guest's BYE drops it with LEFT")
	var ended := []
	g1.session_ended.connect(func(why: int) -> void: ended.append(why))
	host.close()
	_pump(net, [host, g1], 10)
	_check(ended == [Reason.HOST_CLOSING], "host closing ends the guests' session (HOST_CLOSING)")


func _test_link_loss() -> void:
	var r := _room(2, 30.0)
	var net: LoopbackNetwork = r[0]
	var host: Session = r[1]
	var guest: Session = r[2]
	if not _check(_connect_all(net, [host, guest]), "link loss: connected"):
		return
	var left := []
	host.peer_left.connect(func(p: int, why: int, _last: int) -> void: left.append([p, why]))
	var ended := []
	guest.session_ended.connect(func(why: int) -> void: ended.append(why))
	net.drop_link(host.transport as LoopbackTransport, 2)
	_pump(net, [host, guest], 10)
	_check(left == [[2, Reason.DISCONNECTED]] and ended == [Reason.DISCONNECTED],
		"transport DISCONNECTED drops the peer on both sides")
