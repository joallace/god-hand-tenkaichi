class_name WebRtcTransport
extends Transport
## Transport over WebRTC data channels, brokered by a signaling server
## (docs/web_online.md, "Design contract"). Desktop gets WebRTC from the
## webrtc-native GDExtension (addons/webrtc_native), the web build from the
## browser; `available()` says whether either is there.
##
## Host: `var t := WebRtcTransport.new(); t.host_room(signaling, game_id,
## max_guests)`; `room_opened(code)` fires once the server gave the room a
## code. Each guest that joins gets one WebRTCPeerConnection (the host
## offers) and, once connected, the lowest free link id >= FIRST_GUEST_PEER;
## guests beyond `max_guests` are refused through signaling. The host keeps
## its signaling socket for the room's lifetime (`signaling_lost()` if it
## drops: no new joins, existing links keep playing).
## Guest: `t.join_room(signaling, code, game_id)`; the host link is
## HOST_PEER. Every failure before CONNECTED (server error, room closed, ICE
## failure, no connection within Tuning.net.webrtc_connect_timeout_frames)
## ends in DISCONNECTED for HOST_PEER with `last_error_text()` saying why;
## server errors also fire `signaling_error(code, text)`. Once connected the
## guest closes its signaling socket after webrtc_signaling_grace_frames.
##
## Channels are negotiated data channels with fixed ids (no extra
## signaling): 0 = UNRELIABLE (unordered, no retransmits), 1 = RELIABLE,
## 2 = BULK (ordered, reliable). CONNECTED once all three are open; ICE
## failure, a closed connection or channel -> DISCONNECTED. RELIABLE/BULK
## messages are cut into data-channel messages of at most
## Tuning.net.webrtc_chunk_bytes (1-byte header: CHUNK_MORE / CHUNK_LAST) and
## reassembled; a reassembly over Tuning.net.max_bulk_bytes or a bad header
## drops the link. UNRELIABLE is sent whole (Protocol keeps it under
## max_packet_bytes).
## RELIABLE/BULK chunks are paced: at most Tuning.net.webrtc_send_budget_bytes
## per channel and link go out per poll() (the rest wait, in order), since
## the browser's data channel buffers only 64 KiB of received messages
## between two polls and silently drops the rest (Godot's
## WebRTCDataChannelJS: "Buffer full! Dropping data.").
##
## Frames (timeouts) are counted per `poll()`; the game polls once per
## physics frame. Sends are immediate, `flush()` is a no-op.

signal room_opened(code: String)
## A server `error` op (code from the protocol) or the signaling socket
## failing before the room opened / the guest connected ("signaling_closed").
## `text` is user-facing.
signal signaling_error(code: String, text: String)
## Host: the signaling socket dropped after the room opened.
signal signaling_lost()

const CHUNK_LAST := 0
const CHUNK_MORE := 1
const CHUNK_HEADER := 1
## signaling_error code for a socket that closed (not a server error code).
const SIGNALING_CLOSED := "signaling_closed"
## Host -> guest `signal` data refusing a link: {"type": SIGNAL_REJECT,
## "reason": <error code>}.
const SIGNAL_REJECT := "reject"
const ROOM_FULL := "room_full"
## The host's signaling sid (guests are 2, 3, ...; not link ids).
const SIGNAL_HOST_SID := 1
## Candidates kept per link while its remote description is missing.
const MAX_EARLY_CANDIDATES := 64

const TEXT_UNREACHABLE := "Could not reach the host (a TURN relay may be needed)"
const TEXT_NO_REPLY := "No reply from the signaling server"
const TEXT_ROOM_CLOSED := "The host closed the room"
const ERROR_TEXTS := {
	"bad_request": "The signaling server refused the request",
	"room_not_found": "No room with that code",
	"room_full": "The room is full",
	"version_mismatch": "Version mismatch with the host",
	"rate_limited": "Too many attempts, try again in a moment",
	"server_full": "The server is full, try again later",
	"already_in_room": "Already in a room",
}

## Data channel options per Transport.Channel (same keys on native and web).
const CHANNEL_OPTIONS: Array[Dictionary] = [
	{"negotiated": true, "id": Channel.UNRELIABLE, "ordered": false, "maxRetransmits": 0},
	{"negotiated": true, "id": Channel.RELIABLE, "ordered": true},
	{"negotiated": true, "id": Channel.BULK, "ordered": true},
]
const CHANNEL_LABELS: Array[String] = ["unreliable", "reliable", "bulk"]


class Link:
	## Transport link id (host: assigned at peer_joined, guest: HOST_PEER).
	var id: int
	## Signaling sid of the far side.
	var sid: int
	var pc: WebRTCPeerConnection
	var channels: Array[WebRTCDataChannel] = []
	var open := false
	## Polls since the link was created / since disconnect_peer().
	var age := 0
	## Remote description set; candidates before it wait in `candidates`
	## (signaling may reorder, or an answer may never come).
	var remote_set := false
	var candidates: Array[Dictionary] = []
	## A reliable send failed: drop the link on the next poll.
	var failed := false
	## Per channel: chunks of the message being reassembled, and their size.
	var rx: Array = [[], [], []]
	var rx_size: Array[int] = [0, 0, 0]
	## Per channel: chunks waiting for the send budget, and the bytes sent
	## since the last poll().
	var tx: Array = [[], [], []]
	var tx_sent: Array[int] = [0, 0, 0]


static var _available_cached := -1

var _signaling: SignalingChannel = null
var _host := false
var _max_guests := 0
var _room := ""
var _ice_servers: Array = []
var _last_error := ""
## Guest: polls since join_room(); -1 once connected or failed.
var _join_frames := -1
## Guest: got `joined` (the server answered).
var _joined := false
## Guest: polls since CONNECTED while signaling is still open.
var _grace := 0
## Guest: the join failed (DISCONNECTED already reported).
var _failed := false
var _closed := true
## link id -> Link, and sid -> link id.
var _links: Dictionary = {}
var _by_sid: Dictionary = {}
## Links dropped with disconnect_peer(), closing once drained.
var _closing: Array[Link] = []
var _events: Array[Dictionary] = []


## True when WebRTC can actually be used here: the browser's (web) or the
## webrtc-native extension's (desktop). Without the extension Godot still
## creates a WebRTCPeerConnection whose initialize() reports OK, so this
## checks for the extension's class instead.
static func available() -> bool:
	if _available_cached < 0:
		_available_cached = 1 if OS.has_feature("web") or ClassDB.class_exists(&"WebRTCLibPeerConnection") else 0
	return _available_cached == 1


## Open a room on `signaling` for up to `max_guests` guests; `game_id` must
## match the joiners' exactly ("%d:%s" % [Protocol.PROTOCOL_VERSION,
## ContentHash.compute()]). The code arrives as room_opened. Returns an Error
## (ERR_INVALID_PARAMETER, ERR_UNAVAILABLE without WebRTC, ERR_CANT_CONNECT
## for a dead signaling channel).
func host_room(signaling: SignalingChannel, game_id: String, max_guests: int) -> Error:
	var err := _open(signaling, true)
	if err != OK:
		return err
	if max_guests < 1:
		_closed = true
		return ERR_INVALID_PARAMETER
	_max_guests = mini(max_guests, MAX_PEER_ID - FIRST_GUEST_PEER + 1)
	_signaling.send({"op": "host", "game": game_id, "max_guests": _max_guests})
	return OK


## Join room `code` (case-insensitive) on `signaling`. Returns an Error as
## host_room does; otherwise the outcome is CONNECTED or DISCONNECTED for
## HOST_PEER (see last_error_text()).
func join_room(signaling: SignalingChannel, code: String, game_id: String) -> Error:
	var c := code.strip_edges().to_upper()
	if c.is_empty():
		return ERR_INVALID_PARAMETER
	var err := _open(signaling, false)
	if err != OK:
		return err
	_join_frames = 0
	_signaling.send({"op": "join", "room": c, "game": game_id})
	return OK


## The room's code ("" until known).
func room_code() -> String:
	return _room


## Why the join failed / the room couldn't open ("" if it didn't).
func last_error_text() -> String:
	return _last_error


## Frames a guest may take to connect (Session waits at least this long).
func connect_timeout_frames() -> int:
	return 0 if _host else Tuning.net.webrtc_connect_timeout_frames


## User-facing text for a signaling error code.
static func error_text(code: String, message: String = "") -> String:
	if ERROR_TEXTS.has(code):
		return ERROR_TEXTS[code]
	return "Signaling error (%s)" % (message if not message.is_empty() else code)


func send(peer: int, channel: int, bytes: PackedByteArray) -> void:
	var link: Link = _links.get(peer)
	if link == null or not link.open or link.failed or channel < 0 or channel >= CHANNEL_COUNT:
		return
	var ch := link.channels[channel]
	# A link the far side already closed fails here before poll() notices;
	# skip it rather than have the native side log a failed send.
	if ch.get_ready_state() != WebRTCDataChannel.STATE_OPEN \
			or link.pc.get_connection_state() != WebRTCPeerConnection.STATE_CONNECTED:
		return
	if channel == Channel.UNRELIABLE:
		ch.put_packet(bytes)
		return
	var step := Tuning.net.webrtc_chunk_bytes - CHUNK_HEADER
	var queue: Array = link.tx[channel]
	var off := 0
	while true:
		var n := mini(step, bytes.size() - off)
		var last := off + n >= bytes.size()
		var chunk := PackedByteArray([CHUNK_LAST if last else CHUNK_MORE])
		chunk.append_array(bytes.slice(off, off + n))
		queue.append(chunk)
		off += n
		if last:
			break
	_pump_tx(link, channel)


## Send queued chunks of `channel` while this poll's budget lasts (one chunk
## always fits a fresh budget).
func _pump_tx(link: Link, channel: int) -> void:
	var queue: Array = link.tx[channel]
	var ch := link.channels[channel]
	while not queue.is_empty() and not link.failed:
		var chunk: PackedByteArray = queue[0]
		if link.tx_sent[channel] > 0 \
				and link.tx_sent[channel] + chunk.size() > Tuning.net.webrtc_send_budget_bytes:
			return
		if ch.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
			return
		if ch.put_packet(chunk) != OK:
			link.failed = true
			return
		link.tx_sent[channel] += chunk.size()
		queue.pop_front()


## New poll: fresh send budgets, then what waited for them.
func _refill_tx(link: Link) -> void:
	for c: int in [Channel.RELIABLE, Channel.BULK]:
		link.tx_sent[c] = 0
		if link.open:
			_pump_tx(link, c)


func poll() -> Array[Dictionary]:
	if _closed:
		return [] as Array[Dictionary]
	_poll_signaling()
	for id: int in _links.keys():
		var link: Link = _links.get(id)
		if link != null:
			_refill_tx(link)
			_poll_link(link)
	_poll_closing()
	if not _host and not _failed and _join_frames >= 0:
		_join_frames += 1
		if _join_frames > Tuning.net.webrtc_connect_timeout_frames:
			_fail(TEXT_UNREACHABLE if _joined else TEXT_NO_REPLY)
	if not _host and _join_frames < 0 and not _failed and _signaling.is_alive():
		_grace += 1
		if _grace > Tuning.net.webrtc_signaling_grace_frames:
			_signaling.close()
	var out := _events
	_events = []
	return out


func disconnect_peer(peer: int) -> void:
	var link: Link = _links.get(peer)
	if link == null:
		return
	_unmap(link)
	if link.open:
		link.age = 0
		_closing.append(link)
	else:
		link.pc.close()


func close() -> void:
	for id: int in _links:
		(_links[id] as Link).pc.close()
	for link in _closing:
		link.pc.close()
	_links.clear()
	_by_sid.clear()
	_closing.clear()
	_events.clear()
	if _signaling != null:
		_signaling.close()
	_closed = true


func is_host() -> bool:
	return _host


func connected_peers() -> Array[int]:
	var out: Array[int] = []
	for id: int in _links:
		if (_links[id] as Link).open:
			out.append(id)
	out.sort()
	return out


# --- internals ------------------------------------------------------------------

func _open(signaling: SignalingChannel, host: bool) -> Error:
	close()
	if signaling == null:
		return ERR_INVALID_PARAMETER
	if not available():
		return ERR_UNAVAILABLE
	if not signaling.is_alive():
		return ERR_CANT_CONNECT
	_signaling = signaling
	_host = host
	_room = ""
	_ice_servers = []
	_last_error = ""
	_join_frames = -1
	_joined = false
	_grace = 0
	_failed = false
	_closed = false
	return OK


func _poll_signaling() -> void:
	# Keep pumping after the guest closed it (the close frame has to go out).
	for msg: Dictionary in _signaling.poll():
		if _closed:
			return
		match str(msg.get("op", "")):
			"hosted":
				if _host and _room.is_empty():
					_room = str(msg.get("room", ""))
					_ice_servers = _ice_list(msg.get("ice_servers"))
					room_opened.emit(_room)
			"joined":
				if not _host and not _joined and not _failed:
					_joined = true
					_room = str(msg.get("room", ""))
					_ice_servers = _ice_list(msg.get("ice_servers"))
					_new_link(HOST_PEER, SIGNAL_HOST_SID)
			"peer_joined":
				if _host:
					_on_peer_joined(_int(msg.get("peer")))
			"peer_left":
				if _host:
					var link: Link = _links.get(_by_sid.get(_int(msg.get("peer")), NO_PEER))
					if link != null and not link.open:
						_unmap(link)
						link.pc.close()
			"signal":
				var data: Variant = msg.get("data")
				if data is Dictionary:
					_on_signal(_int(msg.get("from")), data)
			"room_closed":
				if not _host and _join_frames >= 0 and not _failed:
					_fail(TEXT_ROOM_CLOSED)
			"error":
				var code := str(msg.get("code", ""))
				var text := error_text(code, str(msg.get("message", "")))
				if _host and _room.is_empty() or not _host and _join_frames >= 0:
					_last_error = text
				signaling_error.emit(code, text)
				if not _host and _join_frames >= 0 and not _failed:
					_fail(text)
			SignalingChannel.OP_CLOSED:
				var text := str(msg.get("text", SignalingClient.TEXT_LOST))
				if _host:
					if _room.is_empty():
						if _last_error.is_empty():
							_last_error = text
							signaling_error.emit(SIGNALING_CLOSED, text)
					else:
						signaling_lost.emit()
				elif _join_frames >= 0 and not _failed:
					signaling_error.emit(SIGNALING_CLOSED, text)
					_fail(text)


func _on_peer_joined(sid: int) -> void:
	if sid <= 0 or _by_sid.has(sid):
		return
	var id := lowest_free_peer_id(_links)
	if _links.size() >= _max_guests or id == NO_PEER:
		_signaling.send({"op": "signal", "to": sid, "data": {"type": SIGNAL_REJECT, "reason": ROOM_FULL}})
		return
	var link := _new_link(id, sid)
	if link != null:
		link.pc.create_offer()


func _on_signal(from: int, data: Dictionary) -> void:
	var link: Link = _links.get(_by_sid.get(from, NO_PEER))
	var type := str(data.get("type", ""))
	if not _host and type == SIGNAL_REJECT and from == SIGNAL_HOST_SID:
		if _join_frames >= 0 and not _failed:
			_fail(error_text(str(data.get("reason", ""))))
		return
	if link == null:
		return
	match type:
		"offer", "answer":
			# The guest takes offers, the host answers; one remote description.
			if link.remote_set or (type == "offer") == _host:
				return
			if link.pc.set_remote_description(type, str(data.get("sdp", ""))) != OK:
				return
			link.remote_set = true
			for c in link.candidates:
				_add_candidate(link, c)
			link.candidates.clear()
		"candidate":
			if link.remote_set:
				_add_candidate(link, data)
			elif link.candidates.size() < MAX_EARLY_CANDIDATES:
				link.candidates.append(data)


func _add_candidate(link: Link, data: Dictionary) -> void:
	link.pc.add_ice_candidate(str(data.get("mid", "")), _int(data.get("index")), str(data.get("sdp", "")))


func _new_link(id: int, sid: int) -> Link:
	var link := Link.new()
	link.id = id
	link.sid = sid
	link.pc = WebRTCPeerConnection.new()
	if link.pc.initialize({"iceServers": _ice_servers}) != OK:
		if not _host:
			_fail(TEXT_UNREACHABLE)
		return null
	link.pc.session_description_created.connect(_on_description.bind(sid))
	link.pc.ice_candidate_created.connect(_on_candidate.bind(sid))
	for c in CHANNEL_COUNT:
		var ch := link.pc.create_data_channel(CHANNEL_LABELS[c], CHANNEL_OPTIONS[c])
		if ch == null:
			link.pc.close()
			if not _host:
				_fail(TEXT_UNREACHABLE)
			return null
		ch.write_mode = WebRTCDataChannel.WRITE_MODE_BINARY
		link.channels.append(ch)
	_links[id] = link
	_by_sid[sid] = id
	return link


func _on_description(type: String, sdp: String, sid: int) -> void:
	var link: Link = _links.get(_by_sid.get(sid, NO_PEER))
	if link == null:
		return
	link.pc.set_local_description(type, sdp)
	_signal_to(sid, {"type": type, "sdp": sdp})


func _on_candidate(mid: String, index: int, sdp: String, sid: int) -> void:
	if _by_sid.has(sid):
		_signal_to(sid, {"type": "candidate", "mid": mid, "index": index, "sdp": sdp})


func _signal_to(sid: int, data: Dictionary) -> void:
	if _signaling != null and _signaling.is_alive():
		_signaling.send({"op": "signal", "to": sid, "data": data})


func _poll_link(link: Link) -> void:
	link.pc.poll()
	for ch in link.channels:
		ch.poll()
	link.age += 1
	var cs := link.pc.get_connection_state()
	if link.failed or cs == WebRTCPeerConnection.STATE_FAILED or cs == WebRTCPeerConnection.STATE_CLOSED:
		_lose(link)
		return
	if not link.open:
		for ch in link.channels:
			if ch.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
				# The guest's whole join is timed in poll(); the host drops a
				# joiner that never connects.
				if _host and link.age > Tuning.net.webrtc_connect_timeout_frames:
					_unmap(link)
					link.pc.close()
				return
		link.open = true
		if not _host:
			_join_frames = -1
		_events.append(make_event(EventType.CONNECTED, link.id))
	for c in CHANNEL_COUNT:
		var ch := link.channels[c]
		while ch.get_available_packet_count() > 0:
			var pkt := ch.get_packet()
			if c == Channel.UNRELIABLE:
				_events.append(make_event(EventType.PACKET, link.id, c, pkt))
			elif not _reassemble(link, c, pkt):
				_lose(link)
				return
		if ch.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
			_lose(link)
			return


## Add one chunk; false on a protocol violation.
func _reassemble(link: Link, c: int, pkt: PackedByteArray) -> bool:
	if pkt.is_empty() or pkt[0] > CHUNK_MORE:
		return false
	var parts: Array = link.rx[c]
	link.rx_size[c] += pkt.size() - CHUNK_HEADER
	if link.rx_size[c] > Tuning.net.max_bulk_bytes:
		return false
	parts.append(pkt.slice(CHUNK_HEADER))
	if pkt[0] == CHUNK_MORE:
		return true
	var whole := PackedByteArray()
	if parts.size() == 1:
		whole = parts[0]
	else:
		for p: PackedByteArray in parts:
			whole.append_array(p)
	parts.clear()
	link.rx_size[c] = 0
	_events.append(make_event(EventType.PACKET, link.id, c, whole))
	return true


func _lose(link: Link) -> void:
	_unmap(link)
	link.pc.close()
	if link.open:
		_events.append(make_event(EventType.DISCONNECTED, link.id))
	elif not _host and not _failed:
		_fail(TEXT_UNREACHABLE)


## Guest: the join failed with `text`.
func _fail(text: String) -> void:
	_failed = true
	_join_frames = -1
	_last_error = text
	for id: int in _links:
		(_links[id] as Link).pc.close()
	_links.clear()
	_by_sid.clear()
	_signaling.close()
	_events.append(make_event(EventType.DISCONNECTED, HOST_PEER))


func _poll_closing() -> void:
	for i in range(_closing.size() - 1, -1, -1):
		var link := _closing[i]
		_refill_tx(link)
		link.pc.poll()
		var done := link.age >= Tuning.net.webrtc_close_linger_frames
		for ch in link.channels:
			ch.poll()
			while ch.get_available_packet_count() > 0:
				ch.get_packet()
			done = done or ch.get_ready_state() != WebRTCDataChannel.STATE_OPEN
		link.age += 1
		if done:
			link.pc.close()
			_closing.remove_at(i)


func _unmap(link: Link) -> void:
	if _links.get(link.id) == link:
		_links.erase(link.id)
	if _by_sid.get(link.sid) == link.id:
		_by_sid.erase(link.sid)


static func _ice_list(v: Variant) -> Array:
	return (v as Array).duplicate(true) if v is Array else []


## JSON numbers arrive as floats.
static func _int(v: Variant) -> int:
	return int(v) if v is float or v is int else 0
