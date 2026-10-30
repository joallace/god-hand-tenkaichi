extends Node
## SignalingClient against a tiny in-process WebSocket server (TCPServer +
## WebSocketPeer.accept_stream) is covered at the end. WebRtcTransport (docs/web_online.md, "Design contract") with real WebRTC
## (webrtc-native) in one process, brokered by LocalSignaling: a host and 3
## guests connect (ids 2, 3, 4), every channel carries packets both ways
## (RELIABLE/BULK in order, a ~1 MB BULK message chunked and reassembled), a
## leaving guest frees its id for the next joiner, the host closing reaches
## every guest, and each way a join can fail ends in DISCONNECTED for
## HOST_PEER with a sensible last_error_text().
## Run as a scene:  godot --headless res://tests/webrtc_transport_test.tscn

const GAME := "2:test"
## Pump iterations before a wait gives up, and the real time per iteration
## (WebRTC runs on its own threads).
const MAX_FRAMES := 600
const FRAME_MS := 2
const ORDERED_COUNT := 20
const BULK_BYTES := 1 << 20
const UNRELIABLE_COUNT := 10
## Local port for the SignalingClient test server.
const WS_PORT := 18787

var _failures := 0
## Transport -> Array of events received (all of them, in order).
var _seen: Dictionary = {}


func _ready() -> void:
	_check(WebRtcTransport.available(), "WebRTC is available (webrtc-native loaded)")
	var tests: Array[Callable] = [
		_test_room, _test_join_errors, _test_room_full_at_host, _test_connect_timeout,
		_test_host_signaling_lost, _test_signaling_client,
	]
	for t in tests:
		t.call()
	print("WEBRTC TRANSPORT TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- harness ------------------------------------------------------------------

func _pump(transports: Array, frames: int = 1) -> void:
	for i in frames:
		for t: WebRtcTransport in transports:
			var log: Array = _seen.get_or_add(t, [])
			log.append_array(t.poll())
		OS.delay_msec(FRAME_MS)


## Pump until `cond` holds (true) or MAX_FRAMES pass (false).
func _pump_until(transports: Array, cond: Callable) -> bool:
	for i in MAX_FRAMES:
		if cond.call():
			return true
		_pump(transports)
	return cond.call()


func _events(t: Transport, type: int) -> Array:
	return (_seen.get(t, []) as Array).filter(func(e: Dictionary) -> bool: return e["type"] == type)


func _packets(t: Transport, channel: int, peer: int) -> Array:
	return _events(t, Transport.EventType.PACKET).filter(
		func(e: Dictionary) -> bool: return e["channel"] == channel and e["peer"] == peer)


func _disconnected(t: Transport, peer: int) -> bool:
	return _events(t, Transport.EventType.DISCONNECTED).any(func(e: Dictionary) -> bool: return e["peer"] == peer)


func _connected(t: Transport, peer: int) -> bool:
	return _events(t, Transport.EventType.CONNECTED).any(func(e: Dictionary) -> bool: return e["peer"] == peer)


func _open_room(hub: LocalSignaling, max_guests: int) -> WebRtcTransport:
	var host := WebRtcTransport.new()
	var codes: Array[String] = []
	host.room_opened.connect(func(c: String) -> void: codes.append(c))
	if host.host_room(hub.create_client(), GAME, max_guests) != OK:
		return null
	if not _pump_until([host], func() -> bool: return not codes.is_empty()):
		return null
	return host


func _join(hub: LocalSignaling, code: String, game: String = GAME) -> WebRtcTransport:
	var g := WebRtcTransport.new()
	g.join_room(hub.create_client(), code, game)
	return g


static func _payload(tag: int, n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = (tag * 31 + i * 7) & 0xFF
	return b


## Every message `peer` sent on `channel` arrived at `t` once, in order.
func _ordered_ok(t: Transport, channel: int, peer: int, tag: int) -> bool:
	var got := _packets(t, channel, peer)
	if got.size() != ORDERED_COUNT:
		return false
	for i in ORDERED_COUNT:
		if got[i]["data"] != _payload(tag + i, i * 3):
			return false
	return true


# --- tests --------------------------------------------------------------------

func _test_room() -> void:
	var hub := LocalSignaling.new()
	var host := _open_room(hub, 3)
	if not _check(host != null, "room: host gets room_opened"):
		return
	var code := host.room_code()
	var alphabet_ok := code.length() == LocalSignaling.CODE_LENGTH
	for ch in code:
		alphabet_ok = alphabet_ok and LocalSignaling.CODE_ALPHABET.contains(ch)
	_check(alphabet_ok, "room: code %s uses the contract alphabet" % code)
	var guests: Array[WebRtcTransport] = []
	for i in 3:
		# one guest types the code in lower case
		guests.append(_join(hub, code.to_lower() if i == 1 else code))
	var all: Array = [host]
	all.append_array(guests)
	var up := _pump_until(all, func() -> bool:
		return host.connected_peers().size() == 3 and guests.all(func(g: WebRtcTransport) -> bool: return _connected(g, Transport.HOST_PEER)))
	if not _check(up, "room: 3 guests connect (host sees %s)" % str(host.connected_peers())):
		return
	_check(host.connected_peers() == ([2, 3, 4] as Array[int]), "room: link ids 2, 3, 4")
	_check(guests.all(func(g: WebRtcTransport) -> bool: return g.connected_peers() == ([Transport.HOST_PEER] as Array[int]) and not g.is_host()),
		"room: each guest sees one link, HOST_PEER")

	# packets on every channel, both ways
	for gi in guests.size():
		var g := guests[gi]
		var id := 2 + gi
		for c in [Transport.Channel.RELIABLE, Transport.Channel.BULK]:
			for i in ORDERED_COUNT:
				host.send(id, c, _payload(100 * id + 10 * c + i, i * 3))
				g.send(Transport.HOST_PEER, c, _payload(1000 * id + 10 * c + i, i * 3))
		for i in UNRELIABLE_COUNT:
			host.send(id, Transport.Channel.UNRELIABLE, _payload(id, 8))
			g.send(Transport.HOST_PEER, Transport.Channel.UNRELIABLE, _payload(id + 50, 8))
	var big := _payload(9, BULK_BYTES)
	host.send(2, Transport.Channel.BULK, big)
	guests[2].send(Transport.HOST_PEER, Transport.Channel.BULK, big)
	var B := Transport.Channel.BULK
	_pump_until(all, func() -> bool:
		return _packets(guests[0], B, 1).size() == ORDERED_COUNT + 1 and _packets(host, B, 4).size() == ORDERED_COUNT + 1)
	var ok_r := true
	var ok_u := true
	for gi in guests.size():
		var g := guests[gi]
		var id := 2 + gi
		for c in [Transport.Channel.RELIABLE, Transport.Channel.BULK]:
			var to_g := _packets(g, c, Transport.HOST_PEER)
			var to_h := _packets(host, c, id)
			for i in ORDERED_COUNT:
				ok_r = ok_r and to_g.size() > i and to_g[i]["data"] == _payload(100 * id + 10 * c + i, i * 3)
				ok_r = ok_r and to_h.size() > i and to_h[i]["data"] == _payload(1000 * id + 10 * c + i, i * 3)
		var u_g := _packets(g, Transport.Channel.UNRELIABLE, Transport.HOST_PEER)
		var u_h := _packets(host, Transport.Channel.UNRELIABLE, id)
		ok_u = ok_u and not u_g.is_empty() and not u_h.is_empty() \
			and u_g.all(func(e: Dictionary) -> bool: return e["data"] == _payload(id, 8)) \
			and u_h.all(func(e: Dictionary) -> bool: return e["data"] == _payload(id + 50, 8))
	_check(ok_r, "room: RELIABLE and BULK arrive once, in order, both ways (incl. an empty message)")
	_check(ok_u, "room: UNRELIABLE arrives both ways")
	var bulk_g := _packets(guests[0], B, 1)
	var bulk_h := _packets(host, B, 4)
	_check(bulk_g.size() == ORDERED_COUNT + 1 and bulk_g[-1]["data"] == big
		and bulk_h.size() == ORDERED_COUNT + 1 and bulk_h[-1]["data"] == big,
		"room: a %d-byte BULK message is reassembled intact both ways" % BULK_BYTES)

	# the guests left signaling after the grace; the host kept it
	_pump(all, Tuning.net.webrtc_signaling_grace_frames + 2)
	_check(guests.all(func(g: WebRtcTransport) -> bool: return not g._signaling.is_alive()) and host._signaling.is_open(),
		"room: guests close signaling once connected, the host keeps it")

	# a guest leaves: the host sees it, the id is reused
	guests[1].close()
	_check(_pump_until(all, func() -> bool: return _disconnected(host, 3)), "room: guest leaving -> host DISCONNECTED(3)")
	_check(host.connected_peers() == ([2, 4] as Array[int]), "room: host links are now %s" % str(host.connected_peers()))
	var g5 := _join(hub, code)
	all.append(g5)
	_check(_pump_until(all, func() -> bool: return _connected(g5, Transport.HOST_PEER) and host.connected_peers().size() == 3)
		and host.connected_peers() == ([2, 3, 4] as Array[int]), "room: the next guest reuses id 3")

	# a fourth guest while 3 are connected is refused by the host transport
	var g6 := _join(hub, code)
	all.append(g6)
	_check(_pump_until(all, func() -> bool: return _disconnected(g6, Transport.HOST_PEER))
		and g6.last_error_text() == "The room is full" and host.connected_peers().size() == 3,
		"room: a guest past max_guests is refused (%s)" % g6.last_error_text())

	# disconnect_peer: the far side gets DISCONNECTED, this side no event
	host.send(4, Transport.Channel.RELIABLE, _payload(77, 5))
	host.disconnect_peer(4)
	var before := _events(host, Transport.EventType.DISCONNECTED).size()
	_check(_pump_until(all, func() -> bool: return _disconnected(guests[2], Transport.HOST_PEER)),
		"room: disconnect_peer(4) -> that guest gets DISCONNECTED")
	var last_r := _packets(guests[2], Transport.Channel.RELIABLE, 1)
	_check(not last_r.is_empty() and last_r[-1]["data"] == _payload(77, 5), "room: a message queued before disconnect_peer is delivered")
	_check(_events(host, Transport.EventType.DISCONNECTED).size() == before, "room: no event for the side that disconnected")

	# the host closes: every remaining guest gets DISCONNECTED
	host.close()
	var rest: Array = [guests[0], g5]
	_check(_pump_until(rest, func() -> bool:
		return rest.all(func(g: WebRtcTransport) -> bool: return _disconnected(g, Transport.HOST_PEER))),
		"room: host close -> every guest DISCONNECTED")
	_check(host.poll().is_empty(), "room: no events after close()")
	for g in rest:
		g.close()


func _test_join_errors() -> void:
	var hub := LocalSignaling.new()
	var host := _open_room(hub, 2)
	if not _check(host != null, "errors: room opened"):
		return
	var cases := [
		["wrong code", "ZZZZZZ", GAME, "No room with that code", "room_not_found"],
		["version mismatch", host.room_code(), "3:other", "Version mismatch with the host", "version_mismatch"],
	]
	for c: Array in cases:
		var g := WebRtcTransport.new()
		var errs := []
		g.signaling_error.connect(func(code: String, text: String) -> void: errs.append([code, text]))
		g.join_room(hub.create_client(), c[1], c[2])
		var done := _pump_until([host, g], func() -> bool: return _disconnected(g, Transport.HOST_PEER))
		_check(done and g.last_error_text() == c[3] and errs.size() == 1 and errs[0] == [c[4], c[3]],
			"errors: %s -> DISCONNECTED(HOST_PEER) '%s' %s" % [c[0], g.last_error_text(), str(errs)])
		_check(not g._signaling.is_alive(), "errors: %s closes the signaling socket" % c[0])
	_check(_events(host, Transport.EventType.CONNECTED).is_empty(), "errors: the host saw no link")

	# full at the server: max_guests = 1, two joiners still on signaling
	var hub2 := LocalSignaling.new()
	var h2 := _open_room(hub2, 1)
	var a := _join(hub2, h2.room_code())
	var b := _join(hub2, h2.room_code())
	var all: Array = [h2, a, b]
	_check(_pump_until(all, func() -> bool: return _disconnected(b, Transport.HOST_PEER) and _connected(a, Transport.HOST_PEER))
		and b.last_error_text() == "The room is full", "errors: room_full from the server (%s)" % b.last_error_text())
	for t: WebRtcTransport in [host, h2, a, b]:
		t.close()


## Max guests at the host while the server still has room (guests that left
## signaling after connecting don't count there).
func _test_room_full_at_host() -> void:
	var hub := LocalSignaling.new()
	var host := _open_room(hub, 1)
	var a := _join(hub, host.room_code())
	var all: Array = [host, a]
	_pump_until(all, func() -> bool: return _connected(a, Transport.HOST_PEER))
	_pump(all, Tuning.net.webrtc_signaling_grace_frames + 2)
	var b := _join(hub, host.room_code())
	all.append(b)
	_check(_pump_until(all, func() -> bool: return _disconnected(b, Transport.HOST_PEER))
		and b.last_error_text() == "The room is full" and host.connected_peers() == ([2] as Array[int]),
		"full: the host refuses a joiner past max_guests (%s)" % b.last_error_text())
	for t: WebRtcTransport in all:
		t.close()


## The host's answer never reaches... rather the guest's answer never
## reaches the host: ICE can't finish, the guest times out.
func _test_connect_timeout() -> void:
	const TIMEOUT := 40
	var saved := Tuning.net.webrtc_connect_timeout_frames
	Tuning.net.webrtc_connect_timeout_frames = TIMEOUT
	var hub := LocalSignaling.new()
	hub.signal_filter = func(_room: String, _from: int, _to: int, data: Dictionary) -> bool:
		return data.get("type") != "answer"
	var host := _open_room(hub, 2)
	var g := _join(hub, host.room_code())
	var frames := 0
	while frames < MAX_FRAMES and not _disconnected(g, Transport.HOST_PEER):
		_pump([host, g])
		frames += 1
	_check(_disconnected(g, Transport.HOST_PEER) and frames >= TIMEOUT and frames <= TIMEOUT + 2,
		"timeout: guest DISCONNECTED(HOST_PEER) after %d frames (timeout %d)" % [frames, TIMEOUT])
	_check(g.last_error_text() == WebRtcTransport.TEXT_UNREACHABLE, "timeout: '%s'" % g.last_error_text())
	_pump([host], TIMEOUT)
	_check(host._links.is_empty(), "timeout: the host dropped the half-open link too")
	_check(g.connect_timeout_frames() == TIMEOUT and host.connect_timeout_frames() == 0, "timeout: connect_timeout_frames() for Session")
	Tuning.net.webrtc_connect_timeout_frames = saved
	host.close()
	g.close()


func _test_host_signaling_lost() -> void:
	var hub := LocalSignaling.new()
	var host := _open_room(hub, 2)
	var lost := [0]
	host.signaling_lost.connect(func() -> void: lost[0] += 1)
	var g := _join(hub, host.room_code())
	_pump_until([host, g], func() -> bool: return _connected(g, Transport.HOST_PEER) and _connected(host, 2))
	hub.drop(host._signaling)
	_pump([host, g], 3)
	host.send(2, Transport.Channel.RELIABLE, _payload(5, 9))
	_check(_pump_until([host, g], func() -> bool: return not _packets(g, Transport.Channel.RELIABLE, 1).is_empty()) and lost[0] == 1
		and hub.room_codes().is_empty(), "lost: signaling_lost once, the room is gone, the link keeps working")
	var late := _join(hub, host.room_code())
	_check(_pump_until([late], func() -> bool: return _disconnected(late, Transport.HOST_PEER))
		and late.last_error_text() == "No room with that code", "lost: no new joins (%s)" % late.last_error_text())
	host.close()
	g.close()


func _test_signaling_client() -> void:
	var bad := SignalingClient.new()
	_check(bad.connect_to_url("http://x") == ERR_INVALID_PARAMETER, "ws: a non-ws URL is refused")
	var server := TCPServer.new()
	if not _check(server.listen(WS_PORT, "127.0.0.1") == OK, "ws: test server listens"):
		return
	var c := SignalingClient.new()
	c.connect_to_url("ws://127.0.0.1:%d" % WS_PORT)
	c.send({"op": "ping"})  # queued until open
	var peer: WebSocketPeer = null
	var got: Array[Dictionary] = []
	var server_got: Array = []
	for i in MAX_FRAMES:
		if peer == null and server.is_connection_available():
			peer = WebSocketPeer.new()
			peer.accept_stream(server.take_connection())
		if peer != null:
			peer.poll()
			while peer.get_available_packet_count() > 0:
				var m: Variant = JSON.parse_string(peer.get_packet().get_string_from_utf8())
				server_got.append(m)
				if m is Dictionary and m.get("op") == "ping":
					peer.send_text(JSON.stringify({"op": "pong"}))
					peer.send_text("not json")
		got.append_array(c.poll())
		if got.any(func(m: Dictionary) -> bool: return m["op"] == "pong"):
			break
		OS.delay_msec(FRAME_MS)
	var ops := got.map(func(m: Dictionary) -> String: return m["op"])
	_check(ops == [SignalingChannel.OP_OPEN, "pong"] and c.is_open() and server_got == [{"op": "ping"}],
		"ws: opens, flushes the queued message, receives JSON, skips junk (%s)" % str(ops))
	peer.close()
	var closed := false
	for i in MAX_FRAMES:
		peer.poll()
		for m in c.poll():
			closed = closed or (m["op"] == SignalingChannel.OP_CLOSED and m["text"] == SignalingClient.TEXT_LOST)
		if closed:
			break
		OS.delay_msec(FRAME_MS)
	_check(closed and not c.is_alive(), "ws: the server closing -> OP_CLOSED '%s'" % SignalingClient.TEXT_LOST)
	server.stop()
	var saved := Tuning.net.signaling_handshake_timeout_frames
	Tuning.net.signaling_handshake_timeout_frames = 30
	var lost := SignalingClient.new()
	lost.connect_to_url("ws://127.0.0.1:%d" % WS_PORT)
	var text := ""
	for i in MAX_FRAMES:
		for m in lost.poll():
			if m["op"] == SignalingChannel.OP_CLOSED:
				text = m["text"]
		if not text.is_empty():
			break
		OS.delay_msec(FRAME_MS)
	_check(text == SignalingClient.TEXT_UNREACHABLE, "ws: no server -> OP_CLOSED '%s'" % text)
	Tuning.net.signaling_handshake_timeout_frames = saved
