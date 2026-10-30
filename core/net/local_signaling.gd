class_name LocalSignaling
extends RefCounted
## In-process twin of the signaling server (docs/web_online.md, "Signaling
## protocol (v1)") for headless tests: same ops, replies, errors, room codes
## and sids, no sockets. Every message goes through JSON like on the wire
## (numbers come back as floats).
##
##   var hub := LocalSignaling.new()
##   var host_sig := hub.create_client()      # a SignalingChannel
##   host_transport.host_room(host_sig, "1:abc", 3)
##
## Endpoints open on their first poll(). Knobs for tests: `ice_servers`
## (handed out in hosted/joined), `delay_frames` (a message reaches its
## receiver that many of the receiver's polls late), `signal_filter`
## ((code, from_sid, to_sid, data) -> bool; false swallows a `signal`), and
## `drop(endpoint)` (the server loses that socket). Room codes are
## deterministic: the n-th room gets n spelled in CODE_ALPHABET.

const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LENGTH := 6
const HOST_SID := 1
const FIRST_GUEST_SID := 2
## Error codes (the contract's list).
const ERR_BAD_REQUEST := "bad_request"
const ERR_ROOM_NOT_FOUND := "room_not_found"
const ERR_ROOM_FULL := "room_full"
const ERR_VERSION_MISMATCH := "version_mismatch"
const ERR_ALREADY_IN_ROOM := "already_in_room"

var ice_servers: Array = []
var delay_frames: int = 0
var signal_filter: Callable = Callable()

## code -> {"host": WeakRef, "game": String, "max_guests": int,
## "next_sid": int, "guests": {sid: WeakRef}}
var _rooms: Dictionary = {}
var _rooms_made: int = 0


## One endpoint of the hub (what a client's SignalingClient would be).
class Endpoint extends SignalingChannel:
	enum State { CONNECTING, OPEN, CLOSED }

	var hub: LocalSignaling
	var room: String = ""
	var sid: int = 0
	var state: State = State.CONNECTING
	var _frames: int = 0
	## {"at": frame, "msg": Dictionary}
	var _inbox: Array[Dictionary] = []
	var _outbox: Array[Dictionary] = []

	func _init(h: LocalSignaling) -> void:
		hub = h

	func poll() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if state == State.CLOSED:
			return out
		_frames += 1
		if state == State.CONNECTING:
			state = State.OPEN
			out.append({"op": OP_OPEN})
			var queued := _outbox
			_outbox = []
			for m in queued:
				hub._handle(self, m)
		while not _inbox.is_empty() and int(_inbox[0]["at"]) <= _frames:
			var msg: Dictionary = _inbox.pop_front()["msg"]
			out.append(msg)
			if msg["op"] == OP_CLOSED:
				_inbox.clear()
				state = State.CLOSED
				break
		return out

	func send(msg: Dictionary) -> void:
		match state:
			State.CONNECTING:
				_outbox.append(msg)
			State.OPEN:
				if not _closing():
					hub._handle(self, msg)

	func close() -> void:
		if state == State.CLOSED:
			return
		state = State.CLOSED
		_inbox.clear()
		hub._on_closed(self)

	func is_open() -> bool:
		return state == State.OPEN

	func is_alive() -> bool:
		return state != State.CLOSED

	func _deliver(msg: Dictionary) -> void:
		var wire: Variant = JSON.parse_string(JSON.stringify(msg))
		_inbox.append({"at": _frames + 1 + hub.delay_frames, "msg": wire})

	## The server closed this socket; OP_CLOSED is already queued.
	func _closing() -> bool:
		return not _inbox.is_empty() and _inbox.back()["msg"]["op"] == OP_CLOSED

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and state != State.CLOSED:
			hub._on_closed(self)


func create_client() -> SignalingChannel:
	return Endpoint.new(self)


## Codes of the open rooms.
func room_codes() -> Array:
	return _rooms.keys()


## The server loses `endpoint`'s socket: it gets OP_CLOSED, the room sees
## it leave.
func drop(endpoint: SignalingChannel) -> void:
	var ep := endpoint as Endpoint
	if ep == null or ep.state == Endpoint.State.CLOSED or ep._closing():
		return
	ep._deliver({"op": SignalingChannel.OP_CLOSED, "text": SignalingClient.TEXT_LOST})
	_on_closed(ep)


# --- server semantics -----------------------------------------------------------

func _handle(ep: Endpoint, raw: Dictionary) -> void:
	var msg: Variant = JSON.parse_string(JSON.stringify(raw))
	if not msg is Dictionary:
		return
	var m: Dictionary = msg
	match str(m.get("op", "")):
		"host":
			_on_host(ep, m)
		"join":
			_on_join(ep, m)
		"signal":
			_on_signal(ep, m)
		"ping":
			ep._deliver({"op": "pong"})
		_:
			_error(ep, ERR_BAD_REQUEST, "unknown op", false)


func _on_host(ep: Endpoint, m: Dictionary) -> void:
	if not ep.room.is_empty():
		_error(ep, ERR_ALREADY_IN_ROOM, "already in a room", true)
		return
	var game: Variant = m.get("game")
	var max_guests: Variant = m.get("max_guests")
	if not game is String or not (max_guests is float or max_guests is int) or int(max_guests) < 1:
		_error(ep, ERR_BAD_REQUEST, "bad host request", true)
		return
	var code := _new_code()
	_rooms[code] = {"host": weakref(ep), "game": game, "max_guests": int(max_guests),
		"next_sid": FIRST_GUEST_SID, "guests": {}}
	ep.room = code
	ep.sid = HOST_SID
	ep._deliver({"op": "hosted", "room": code, "peer": HOST_SID, "ice_servers": ice_servers})


func _on_join(ep: Endpoint, m: Dictionary) -> void:
	if not ep.room.is_empty():
		_error(ep, ERR_ALREADY_IN_ROOM, "already in a room", true)
		return
	var code: Variant = m.get("room")
	var game: Variant = m.get("game")
	if not code is String or not game is String:
		_error(ep, ERR_BAD_REQUEST, "bad join request", true)
		return
	var key := (code as String).strip_edges().to_upper()
	var room: Dictionary = _rooms.get(key, {})
	if room.is_empty():
		_error(ep, ERR_ROOM_NOT_FOUND, "no such room", true)
		return
	if room["game"] != game:
		_error(ep, ERR_VERSION_MISMATCH, "game build differs from the host's", true)
		return
	if (room["guests"] as Dictionary).size() >= int(room["max_guests"]):
		_error(ep, ERR_ROOM_FULL, "room is full", true)
		return
	var sid: int = room["next_sid"]
	room["next_sid"] = sid + 1
	room["guests"][sid] = weakref(ep)
	ep.room = key
	ep.sid = sid
	ep._deliver({"op": "joined", "room": key, "peer": sid, "ice_servers": ice_servers})
	var host := _ref(room["host"])
	if host:
		host._deliver({"op": "peer_joined", "peer": sid})


func _on_signal(ep: Endpoint, m: Dictionary) -> void:
	var room: Dictionary = _rooms.get(ep.room, {})
	var to: Variant = m.get("to")
	var data: Variant = m.get("data")
	if room.is_empty() or not (to is float or to is int) or not data is Dictionary:
		_error(ep, ERR_BAD_REQUEST, "bad signal", false)
		return
	var dest: Endpoint = null
	if ep.sid == HOST_SID:
		dest = _ref((room["guests"] as Dictionary).get(int(to)))
	elif int(to) == HOST_SID:
		dest = _ref(room["host"])
	if dest == null:
		_error(ep, ERR_BAD_REQUEST, "bad signal target", false)
		return
	if signal_filter.is_valid() and not signal_filter.call(ep.room, ep.sid, int(to), data):
		return
	dest._deliver({"op": "signal", "from": ep.sid, "data": data})


func _on_closed(ep: Endpoint) -> void:
	var room: Dictionary = _rooms.get(ep.room, {})
	if room.is_empty():
		return
	if ep.sid == HOST_SID:
		_rooms.erase(ep.room)
		for sid: int in room["guests"]:
			var g := _ref(room["guests"][sid])
			if g:
				g._deliver({"op": "room_closed"})
				g.room = ""
	else:
		(room["guests"] as Dictionary).erase(ep.sid)
		var host := _ref(room["host"])
		if host:
			host._deliver({"op": "peer_left", "peer": ep.sid})
	ep.room = ""


## `error`; after a failed host/join the server closes the socket.
func _error(ep: Endpoint, code: String, message: String, then_close: bool) -> void:
	ep._deliver({"op": "error", "code": code, "message": message})
	if then_close:
		ep._deliver({"op": SignalingChannel.OP_CLOSED, "text": SignalingClient.TEXT_LOST})


func _new_code() -> String:
	var n := _rooms_made
	_rooms_made += 1
	var base := CODE_ALPHABET.length()
	var code := ""
	for i in CODE_LENGTH:
		code = CODE_ALPHABET[n % base] + code
		n /= base
	return code


static func _ref(w: Variant) -> Endpoint:
	return (w as WeakRef).get_ref() as Endpoint if w is WeakRef else null
