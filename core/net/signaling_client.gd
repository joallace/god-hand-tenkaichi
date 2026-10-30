class_name SignalingClient
extends SignalingChannel
## SignalingChannel over a WebSocketPeer: JSON text frames, one object per
## frame (docs/web_online.md, "Signaling protocol (v1)"). Works the same on
## desktop and web (the browser's WebSocket).
##
##   var s := SignalingClient.new()
##   s.connect_to_url("wss://example.org:8787")   # then hand it to WebRtcTransport
##
## Frames are counted per poll() (the game polls once per physics frame):
## a socket not open after Tuning.net.signaling_handshake_timeout_frames is
## closed with OP_CLOSED "Could not reach the signaling server"; an open one
## sends a `ping` op every Tuning.net.signaling_keepalive_frames (the server
## drops idle sockets). Frames that aren't a JSON object with a String "op"
## are ignored.

const TEXT_UNREACHABLE := "Could not reach the signaling server"
const TEXT_LOST := "Lost the connection to the signaling server"

var _ws: WebSocketPeer = null
var _outbox: Array[Dictionary] = []
var _opened := false
var _alive := false
var _frames := 0
var _next_ping := 0


## Start connecting to `url` (ws:// or wss://). Returns an Error
## (ERR_INVALID_PARAMETER for an unusable URL); otherwise the outcome
## arrives through poll() as OP_OPEN or OP_CLOSED.
func connect_to_url(url: String, tls_options: TLSOptions = null) -> Error:
	close()
	var u := url.strip_edges()
	if not (u.begins_with("ws://") or u.begins_with("wss://")):
		return ERR_INVALID_PARAMETER
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(u, tls_options)
	if err != OK:
		_ws = null
		return err
	_alive = true
	_opened = false
	_frames = 0
	return OK


func poll() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _ws == null:
		return out
	if not _alive:
		# close()d: keep pumping so the close frame goes out, report nothing.
		_ws.poll()
		if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_ws = null
		return out
	_frames += 1
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _opened:
			_opened = true
			_next_ping = _frames + Tuning.net.signaling_keepalive_frames
			out.append({"op": OP_OPEN})
			for m in _outbox:
				_send_now(m)
			_outbox.clear()
		while _ws.get_available_packet_count() > 0:
			var msg := _decode(_ws.get_packet())
			if not msg.is_empty():
				out.append(msg)
		if _frames >= _next_ping:
			_next_ping = _frames + Tuning.net.signaling_keepalive_frames
			_send_now({"op": "ping"})
	elif st == WebSocketPeer.STATE_CLOSING:
		# The server sends `error` and closes right after: read it now, the
		# peer may not keep it once the close completes.
		while _ws.get_available_packet_count() > 0:
			var msg := _decode(_ws.get_packet())
			if not msg.is_empty():
				out.append(msg)
	elif st == WebSocketPeer.STATE_CLOSED:
		# Drain what arrived before the close (an `error` before the server
		# closes the socket).
		while _ws.get_available_packet_count() > 0:
			var msg := _decode(_ws.get_packet())
			if not msg.is_empty():
				out.append(msg)
		out.append({"op": OP_CLOSED, "text": TEXT_LOST if _opened else TEXT_UNREACHABLE})
		_shutdown()
	elif st == WebSocketPeer.STATE_CONNECTING and _frames > Tuning.net.signaling_handshake_timeout_frames:
		out.append({"op": OP_CLOSED, "text": TEXT_UNREACHABLE})
		_ws.close()
		_shutdown()
	return out


func send(msg: Dictionary) -> void:
	if not _alive:
		return
	if _opened:
		_send_now(msg)
	else:
		_outbox.append(msg)


## Nobody polls a closed client: push the close frame out now, then release
## the peer (that closes the TCP socket), so the server always sees us leave
## (a host's room code dies with its socket).
func close() -> void:
	if _ws != null and _alive:
		_ws.close()
		_ws.poll()
	_ws = null
	_shutdown()


func is_open() -> bool:
	return _alive and _opened


func is_alive() -> bool:
	return _alive


## A frame as a protocol message, or {} (not JSON / not an object with a
## String "op"). JSON.parse() rather than parse_string(): no error log.
func _decode(pkt: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(pkt.get_string_from_utf8()) != OK:
		return {}
	var v: Variant = json.data
	if v is Dictionary and (v as Dictionary).get("op") is String:
		return v
	return {}


func _send_now(msg: Dictionary) -> void:
	_ws.send_text(JSON.stringify(msg))


func _shutdown() -> void:
	_alive = false
	_opened = false
	_outbox.clear()
