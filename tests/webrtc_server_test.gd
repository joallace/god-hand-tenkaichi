extends Node
## WebRtcTransport + SignalingClient against the real Python signaling server
## (server/signaling_server.py, docs/web_online.md "Signaling protocol (v1)"):
## the test starts it as a subprocess on a local port, a host opens a room,
## two guests join by code (one typed in lower case), packets cross every
## channel both ways, a wrong code and a wrong build fail with the server's
## error text, and the room code dies with the host.
## Skips (passes with a SKIP line) when python3 + websockets aren't installed.
## Run as a scene:  godot --headless res://tests/webrtc_server_test.tscn

const GAME := "2:server-test"
const PORT := 18788
const URL := "ws://127.0.0.1:%d" % PORT
const SERVER_SCRIPT := "res://server/signaling_server.py"
## Pump iterations before a wait gives up, and the real time per iteration.
const MAX_FRAMES := 1500
const FRAME_MS := 4
const PAYLOAD_BYTES := 40000

var _failures := 0
var _pid := -1
var _seen: Dictionary = {}


func _ready() -> void:
	if not _python_ready():
		print("SKIP webrtc_server_test: python3 with websockets not found")
		print("WEBRTC SERVER TESTS: PASS (skipped)")
		get_tree().quit(0)
		return
	_check(WebRtcTransport.available(), "WebRTC is available (webrtc-native loaded)")
	if _start_server():
		_test_room()
		_test_errors()
	_stop_server()
	print("WEBRTC SERVER TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- server process -------------------------------------------------------------

func _python_ready() -> bool:
	var out: Array = []
	return OS.execute("python3", ["-c", "import websockets"], out, true) == 0


func _start_server() -> bool:
	var script := ProjectSettings.globalize_path(SERVER_SCRIPT)
	_pid = OS.create_process("python3", [script, "--bind", "127.0.0.1", "--port", str(PORT),
		"--log-level", "WARNING"])
	if not _check(_pid > 0, "signaling server process started"):
		return false
	# Wait until the port accepts a TCP connection.
	for i in MAX_FRAMES:
		var tcp := StreamPeerTCP.new()
		if tcp.connect_to_host("127.0.0.1", PORT) == OK:
			for j in 50:
				tcp.poll()
				if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTING:
					break
				OS.delay_msec(FRAME_MS)
			var up := tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
			tcp.disconnect_from_host()
			if up:
				return _check(true, "signaling server listening on %d" % PORT)
		OS.delay_msec(FRAME_MS * 10)
	return _check(false, "signaling server listening on %d" % PORT)


func _stop_server() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1


# --- harness --------------------------------------------------------------------

func _client() -> SignalingClient:
	var c := SignalingClient.new()
	c.connect_to_url(URL)
	return c


func _pump(transports: Array) -> void:
	for t: WebRtcTransport in transports:
		var log: Array = _seen.get_or_add(t, [])
		log.append_array(t.poll())
	OS.delay_msec(FRAME_MS)


func _pump_until(transports: Array, cond: Callable) -> bool:
	for i in MAX_FRAMES:
		if cond.call():
			return true
		_pump(transports)
	return cond.call()


func _has(t: Transport, type: int, peer: int) -> bool:
	return (_seen.get(t, []) as Array).any(
		func(e: Dictionary) -> bool: return e["type"] == type and e["peer"] == peer)


func _got(t: Transport, channel: int, peer: int, size: int) -> bool:
	return (_seen.get(t, []) as Array).any(func(e: Dictionary) -> bool:
		return e["type"] == Transport.EventType.PACKET and e["channel"] == channel \
			and e["peer"] == peer and (e["data"] as PackedByteArray).size() == size)


static func _payload(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = i & 0xFF
	return b


# --- tests ----------------------------------------------------------------------

func _test_room() -> void:
	var host := WebRtcTransport.new()
	var codes: Array[String] = []
	host.room_opened.connect(func(c: String) -> void: codes.append(c))
	_check(host.host_room(_client(), GAME, 3) == OK, "host_room starts")
	if not _check(_pump_until([host], func() -> bool: return not codes.is_empty()),
			"server hands out a room code"):
		host.close()
		return
	var code := codes[0]
	_check(code.length() == 6 and code == host.room_code(), "6-char code (%s)" % code)

	var g1 := WebRtcTransport.new()
	g1.join_room(_client(), code, GAME)
	var g2 := WebRtcTransport.new()
	g2.join_room(_client(), code.to_lower(), GAME)
	var all := [host, g1, g2]
	_check(_pump_until(all, func() -> bool:
		return _has(g1, Transport.EventType.CONNECTED, Transport.HOST_PEER) \
			and _has(g2, Transport.EventType.CONNECTED, Transport.HOST_PEER) \
			and host.connected_peers().size() == 2), "two guests connect through the server")
	var expected: Array[int] = [2, 3]
	_check(host.connected_peers() == expected, "host links are 2 and 3")

	var big := _payload(PAYLOAD_BYTES)
	for ch in Transport.CHANNEL_COUNT:
		host.send(2, ch, _payload(100 + ch))
		g2.send(Transport.HOST_PEER, ch, _payload(200 + ch))
	host.send(3, Transport.Channel.BULK, big)
	for t: WebRtcTransport in all:
		t.flush()
	_check(_pump_until(all, func() -> bool:
		for ch in Transport.CHANNEL_COUNT:
			if not _got(g1, ch, Transport.HOST_PEER, 100 + ch) or not _got(host, ch, 3, 200 + ch):
				return false
		return _got(g2, Transport.Channel.BULK, Transport.HOST_PEER, PAYLOAD_BYTES)),
		"packets cross every channel both ways (and a chunked bulk message)")

	host.close()
	_check(_pump_until([g1, g2], func() -> bool:
		return _has(g1, Transport.EventType.DISCONNECTED, Transport.HOST_PEER) \
			and _has(g2, Transport.EventType.DISCONNECTED, Transport.HOST_PEER)),
		"host close reaches both guests")
	g1.close()
	g2.close()

	# The room died with the host's socket.
	var late := WebRtcTransport.new()
	late.join_room(_client(), code, GAME)
	_check(_pump_until([late], func() -> bool:
		return _has(late, Transport.EventType.DISCONNECTED, Transport.HOST_PEER)),
		"joining a closed room fails")
	_check(late.last_error_text() == WebRtcTransport.error_text("room_not_found"),
		"closed room: '%s'" % late.last_error_text())
	late.close()


func _test_errors() -> void:
	var host := WebRtcTransport.new()
	var codes: Array[String] = []
	host.room_opened.connect(func(c: String) -> void: codes.append(c))
	host.host_room(_client(), GAME, 1)
	if not _check(_pump_until([host], func() -> bool: return not codes.is_empty()), "second room opens"):
		host.close()
		return
	var wrong_build := WebRtcTransport.new()
	wrong_build.join_room(_client(), codes[0], GAME + "-other")
	var no_room := WebRtcTransport.new()
	no_room.join_room(_client(), "ZZZZZZ" if codes[0] != "ZZZZZZ" else "YYYYYY", GAME)
	var all := [host, wrong_build, no_room]
	_check(_pump_until(all, func() -> bool:
		return _has(wrong_build, Transport.EventType.DISCONNECTED, Transport.HOST_PEER) \
			and _has(no_room, Transport.EventType.DISCONNECTED, Transport.HOST_PEER)),
		"wrong build and unknown code both fail")
	_check(wrong_build.last_error_text() == WebRtcTransport.error_text("version_mismatch"),
		"wrong build: '%s'" % wrong_build.last_error_text())
	_check(no_room.last_error_text() == WebRtcTransport.error_text("room_not_found"),
		"unknown code: '%s'" % no_room.last_error_text())
	for t: WebRtcTransport in all:
		t.close()
