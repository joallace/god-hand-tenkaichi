class_name Session
extends RefCounted
## One online room over any Transport (SPEC_ONLINE.md §5, §13; milestone 1
## scope). Host-relayed star: guests only talk to the host (peer 1), the host
## forwards. No sim knowledge: the RollbackDriver joins it to MatchDirector.
##
## Per frame (the driver's order, §7.1):
##   session.local_tick = director.tick
##   session.receive()           # pump transport: handshake, inputs, control
##   session.submit_local_input(slot, tick + delay, frame)   # per local slot
##   session.send_pending()      # INPUT (+ redundancy), INPUT_ACK, PING; flush
## (`update()` = receive + send_pending, for lobbies and tests.)
##
## Inputs: the Session OWNS the feeding of `history` (an InputHistory the
## driver shares with its NetworkInput sources). Every new remote frame is
## stored with `history.add_confirmed` before `input_received` fires, and a
## misprediction fires `mispredicted(slot, tick)`; the driver only has to
## roll back to the minimum tick it saw. Local frames go in through
## `submit_local_input`. Which peer owns which slot comes from the match
## config: `set_slot_owners({slot: peer})` (frames for slots a peer doesn't
## own are dropped). `begin_match()` resets history, acks and TimeSync;
## `end_match()` (the driver leaving) stops INPUT / INPUT_ACK both ways until
## the next begin_match, so a peer still on the old match can't poison the
## new match's acks (an old ack is far ahead of the new ticks, and acks only
## grow: the frames it claims would never be sent) or history.
##
## Routing (§5.2): an INPUT on link X->D for origin O carries frames of O from
## ack(O, D)+1 (every frame D hasn't acked, oldest first, capped by
## redundancy_cap(): max_rollback_frames + input_delay_max + the link's RTT in
## frames), and its `ack_tick_from_dest` = ack(D, O): how
## far O has D's frames. Acks are tracked per (origin, destination) from
## INPUT_ACK (sent every frame on every link: the sender's contiguous
## confirmed tick of every other origin) and from INPUT ack fields. The host
## rebuilds each forwarded INPUT from `history` instead of copying bytes, which
## carries exactly the same frames with the destination's own ack/redundancy.
##
## Liveness: PING every ping_interval_frames per link -> RTT (averaged over
## Tuning.net.rtt_samples) and TimeSync samples (PING and PONG both carry the
## sender's tick). A link silent for disconnect_timeout_frames, a transport
## DISCONNECTED or a BYE drops the peer: the host emits `peer_left` with the
## last tick it confirmed for that peer and relays DROP to the others; a
## guest that loses the host emits `session_ended`.
##
## Security: malformed packets are dropped (Protocol.decode); host-only
## messages (Protocol.is_host_only) are dropped unless they come from the
## host link on a guest; the host only accepts INPUT whose origin is the
## sending link, and HASH/PING/PONG/INPUT_ACK whose sender is the link;
## nothing but HELLO/BYE (host) or WELCOME/REJECT/BYE (guest) is accepted
## from a link before its handshake.

enum Role { HOST, GUEST }
enum State { CONNECTING, CONNECTED, CLOSED }

## Guest: handshake accepted, `local_peer_id` is set.
signal welcomed(peer_id: int)
## Guest: the host refused us (Protocol.Reason); `session_ended` follows.
signal rejected(reason: int, detail: String)
signal peer_joined(peer: int, peer_name: String)
## A peer left: reason is Protocol.Reason (LEFT, TIMEOUT, DISCONNECTED);
## last_tick = last tick of its input the host confirmed (the cut point, §13).
signal peer_left(peer: int, reason: int, last_tick: int)
## The name table changed (join, leave, PEERS from the host).
signal peers_changed()
## Guest: the session is over (host left/lost, rejected). Not emitted by close().
signal session_ended(reason: int)
## A remote input frame newly confirmed into `history`.
signal input_received(origin: int, slot: int, tick: int, frame: InputFrame)
## `history.add_confirmed` reported the sim used a different frame for tick.
signal mispredicted(slot: int, tick: int)
signal command_received(cmd: Dictionary)
signal hash_received(peer: int, tick: int, hash_value: int)
signal resync_received(tick: int, snapshot: Dictionary)
signal snapshot_received(tick: int, snapshot: Dictionary, extra: Dictionary)
signal lobby_state_received(lobby: Dictionary)
## Host: a guest's lobby/room request (OnlineRoom validates it).
signal lobby_request_received(peer: int, req: Dictionary)
signal match_start_received(config: Dictionary, seed_value: int, start: Dictionary)
signal rtt_updated(peer: int, rtt_ms: float)

## Random bytes in a reconnect token.
const TOKEN_BYTES := 8
const MS_PER_USEC := 0.001
## game_build when the project has no version string (editor / dev runs).
const DEV_BUILD := "dev"
## Messages accepted from a link before its handshake completes.
const _HOST_PRE_HANDSHAKE: Array[int] = [Protocol.Type.HELLO, Protocol.Type.BYE]
const _GUEST_PRE_HANDSHAKE: Array[int] = [Protocol.Type.WELCOME, Protocol.Type.REJECT, Protocol.Type.BYE]

var transport: Transport
var role: Role
var state: State = State.CONNECTING
## Host: Transport.HOST_PEER. Guest: Transport.NO_PEER until WELCOME.
var local_peer_id: int = Transport.NO_PEER
var local_name: String = ""
## What HELLO carries and what the host requires (see default_identity()):
## protocol_version, engine_version, game_build, content_hash.
var identity: Dictionary = {}
## Guest: token from WELCOME (send it back in HELLO to reconnect).
var reconnect_token: String = ""
## Guest: set before connecting to rejoin as the same player (§13).
var hello_reconnect_token: String = ""
var history: InputHistory
var time_sync := TimeSync.new()
## The sim tick this machine is at (the driver sets it every frame).
var local_tick: int = 0
## Host: false once a match runs and joins should get IN_PROGRESS.
var accepting_joins := true
## Host: guests allowed at once.
var max_guests: int = 0
## Host: shared with joiners in WELCOME; change with set_lobby_state().
var lobby_state: Dictionary = {}
## Milliseconds now (() -> float); unset = the engine's monotonic clock.
## Tests point it at LoopbackNetwork.now_ms for exact RTTs.
var clock: Callable = Callable()

## Packets dropped as malformed or not allowed (debug overlay, tests).
var dropped_packets: int = 0

var _frame: int = 0
## Direct links: peer -> {"welcomed": bool, "last_heard": frame,
## "rtt": Array[float], "next_ping": frame, "token": String}
var _links: Dictionary = {}
## Every session member incl. self: peer -> name.
var _names: Dictionary = {}
## slot -> owning peer
var _slot_owner: Dictionary = {}
## origin -> {dest: tick}
var _acks: Dictionary = {}


func _init(t: Transport, session_role: Role, player_name: String, ident: Dictionary = {}) -> void:
	transport = t
	role = session_role
	local_name = player_name
	identity = default_identity()
	identity.merge(ident, true)
	history = InputHistory.new()
	max_guests = Tuning.net.max_humans - 1
	if role == Role.HOST:
		local_peer_id = Transport.HOST_PEER
		state = State.CONNECTED
		_names[local_peer_id] = local_name


static func create_host(t: Transport, player_name: String, ident: Dictionary = {}) -> Session:
	return Session.new(t, Role.HOST, player_name, ident)


static func create_guest(t: Transport, player_name: String, ident: Dictionary = {}) -> Session:
	return Session.new(t, Role.GUEST, player_name, ident)


## This build's identity. content_hash is "" until the caller injects one.
static func default_identity() -> Dictionary:
	var build := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	return {
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"engine_version": int(Engine.get_version_info()["hex"]),
		"game_build": build if not build.is_empty() else DEV_BUILD,
		"content_hash": "",
	}


## Trimmed name, or "" if it is empty, too long (Tuning.net.name_max_len) or
## has control characters.
static func sanitize_name(n: String) -> String:
	const FIRST_PRINTABLE := 0x20
	const DEL := 0x7F
	var s := n.strip_edges()
	if s.is_empty() or s.length() > Tuning.net.name_max_len:
		return ""
	for i in s.length():
		var c := s.unicode_at(i)
		if c < FIRST_PRINTABLE or c == DEL:
			return ""
	return s


func is_host() -> bool:
	return role == Role.HOST


# --- per-frame ----------------------------------------------------------------

func update() -> void:
	receive()
	send_pending()


## Pump the transport and handle everything that arrived; then timeouts.
func receive() -> void:
	if state == State.CLOSED:
		return
	_frame += 1
	for ev: Dictionary in transport.poll():
		match ev["type"]:
			Transport.EventType.CONNECTED:
				_on_connected(ev["peer"])
			Transport.EventType.DISCONNECTED:
				_on_link_lost(ev["peer"], Protocol.Reason.DISCONNECTED)
			Transport.EventType.PACKET:
				_on_packet(ev["peer"], ev["channel"], ev["data"])
		if state == State.CLOSED:
			return
	if not is_host() and state == State.CONNECTING and _links.is_empty() \
			and _frame > maxi(Tuning.net.disconnect_timeout_frames, transport.connect_timeout_frames()):
		_end(Protocol.Reason.TIMEOUT)
		return
	for peer: int in _links.keys():
		if _links.has(peer) and _frame - int(_links[peer]["last_heard"]) > Tuning.net.disconnect_timeout_frames:
			_on_link_lost(peer, Protocol.Reason.TIMEOUT)
			if state == State.CLOSED:
				return


## Send INPUT (with redundancy), INPUT_ACK and due PINGs on every link, then
## flush the transport.
func send_pending() -> void:
	if state != State.CONNECTED:
		transport.flush()
		return
	for dest: int in _links:
		if not _links[dest]["welcomed"]:
			continue
		_send_inputs(dest)
		_send_acks(dest)
		if _frame >= int(_links[dest]["next_ping"]):
			_links[dest]["next_ping"] = _frame + Tuning.net.ping_interval_frames
			_send(dest, Protocol.encode_ping(local_peer_id, _now_ms_u32(), local_tick))
	transport.flush()


# --- match-level API ----------------------------------------------------------

## {slot: peer} for every human slot (CPU slots: leave out).
func set_slot_owners(owners: Dictionary) -> void:
	_slot_owner = owners.duplicate()


func slot_owner(slot: int) -> int:
	return _slot_owner.get(slot, Transport.NO_PEER)


## Slots owned by `peer`, sorted.
func slots_of(peer: int) -> Array[int]:
	var out: Array[int] = []
	for s: int in _slot_owner:
		if _slot_owner[s] == peer:
			out.append(s)
	out.sort()
	return out


## Fresh input log for a match: owners, history reset at `first_tick`,
## acks and TimeSync cleared.
func begin_match(owners: Dictionary, first_tick: int = 1) -> void:
	set_slot_owners(owners)
	history.reset(first_tick)
	_acks.clear()
	time_sync.clear()


## The match is over here: no slot owners, so no INPUT / INPUT_ACK goes out
## and arriving ones are ignored until the next begin_match.
func end_match() -> void:
	_slot_owner.clear()
	_acks.clear()


func in_match() -> bool:
	return not _slot_owner.is_empty()


## Record a local slot's frame for `tick` (sent on send_pending).
## Returns history.add_confirmed's result, or -1 if `slot` isn't ours.
func submit_local_input(slot: int, tick: int, frame: InputFrame) -> int:
	if local_peer_id == Transport.NO_PEER or slot_owner(slot) != local_peer_id:
		return -1
	var t := history.add_confirmed(slot, tick, frame)
	if t >= 0:
		mispredicted.emit(slot, t)
	return t


## Contiguous confirmed tick of every slot `origin` owns (history first_tick
## - 1 if none confirmed; InputHistory.NO_LIMIT if it owns no slot).
func origin_confirmed_tick(origin: int) -> int:
	return history.min_confirmed_tick(slots_of(origin))


## How far `dest` has `origin`'s frames (as known here; exact for dest = us).
func ack(origin: int, dest: int) -> int:
	if dest == local_peer_id:
		var c := origin_confirmed_tick(origin)
		return history.first_tick - 1 if c == InputHistory.NO_LIMIT else c
	return (_acks.get(origin, {}) as Dictionary).get(dest, history.first_tick - 1)


# --- host API -------------------------------------------------------------------

## Host: store and broadcast. (A guest's copy arrives via lobby_state_received.)
func set_lobby_state(lobby: Dictionary) -> bool:
	if not is_host():
		return false
	lobby_state = lobby.duplicate(true)
	return _broadcast(Protocol.encode_lobby_state(lobby_state))


## Guest: a lobby/room request to the host (OnlineRoom defines the ops).
func send_lobby_request(req: Dictionary) -> bool:
	return not is_host() and state == State.CONNECTED and _send(Transport.HOST_PEER, Protocol.encode_lobby_req(req))


func start_match(config: Dictionary, seed_value: int, start: Dictionary = {}) -> bool:
	return is_host() and _broadcast(Protocol.encode_match_start(config, seed_value, start))


## Host only: a sim command {"tick", "kind", ...} to every guest (the host
## applies it locally itself).
func send_command(cmd: Dictionary) -> bool:
	return is_host() and _broadcast(Protocol.encode_cmd(cmd))


func send_resync(peer: int, tick: int, snapshot: Dictionary) -> bool:
	return is_host() and _send(peer, Protocol.encode_resync(tick, snapshot))


func send_snapshot(peer: int, tick: int, snapshot: Dictionary, extra: Dictionary = {}) -> bool:
	return is_host() and _send(peer, Protocol.encode_snapshot(tick, snapshot, extra))


# --- any role -----------------------------------------------------------------

## Guest: HASH to the host. Host: HASH to every guest.
func send_hash(tick: int, hash_value: int) -> bool:
	if state != State.CONNECTED:
		return false
	var b := Protocol.encode_hash(local_peer_id, tick, hash_value)
	return _broadcast(b) if is_host() else _send(Transport.HOST_PEER, b)


## Leave (guest) or close the room (host): BYE to every link, then close the
## transport. No signals. `reason` (Protocol.Reason) defaults to
## HOST_CLOSING / LEFT; guests get it in session_ended.
func close(reason: int = -1) -> void:
	if state == State.CLOSED:
		return
	if reason < 0:
		reason = Protocol.Reason.HOST_CLOSING if is_host() else Protocol.Reason.LEFT
	for peer: int in _links:
		_send(peer, Protocol.encode_bye(reason))
	transport.flush()
	transport.close()
	_links.clear()
	state = State.CLOSED


## Session members (incl. self), sorted.
func peer_ids() -> Array[int]:
	var out: Array[int] = []
	for p: int in _names:
		out.append(p)
	out.sort()
	return out


func peer_name(peer: int) -> String:
	return _names.get(peer, "")


## Directly linked peers that finished the handshake, sorted.
func link_peers() -> Array[int]:
	var out: Array[int] = []
	for p: int in _links:
		if _links[p]["welcomed"]:
			out.append(p)
	out.sort()
	return out


## Averaged RTT to a linked peer in ms (-1 = not measured yet).
func rtt_ms(peer: int) -> float:
	if not _links.has(peer):
		return -1.0
	var s: Array = _links[peer]["rtt"]
	if s.is_empty():
		return -1.0
	var total := 0.0
	for v: float in s:
		total += v
	return total / s.size()


## Worst measured RTT over the direct links (0 if none). A guest's frames
## reach other guests through the host, so a fuller estimate would add the
## host's RTT to them (not shared yet).
func rtt_max_ms() -> float:
	var m := 0.0
	for p: int in _links:
		m = maxf(m, rtt_ms(p))
	return m


## Frames this session has run (receive() calls).
func frame_count() -> int:
	return _frame


# --- events -------------------------------------------------------------------

func _on_connected(peer: int) -> void:
	if is_host():
		_links[peer] = _new_link()
		return
	if peer != Transport.HOST_PEER:
		return  # guests only keep a link to the host
	_links[peer] = _new_link()
	var hello := identity.duplicate()
	hello["name"] = local_name
	hello["reconnect_token"] = hello_reconnect_token
	_send(peer, Protocol.encode_hello(hello))


func _new_link() -> Dictionary:
	return {"welcomed": false, "last_heard": _frame, "rtt": [] as Array[float],
		"next_ping": _frame, "token": ""}


func _on_link_lost(peer: int, reason: int) -> void:
	if not _links.has(peer):
		# A guest's connection attempt failed (the transport says so).
		if not is_host() and peer == Transport.HOST_PEER and state == State.CONNECTING:
			_end(reason)
		return
	if is_host():
		_drop_guest(peer, reason)
	elif peer == Transport.HOST_PEER:
		_end(reason)
	else:
		_links.erase(peer)


func _drop_guest(peer: int, reason: int) -> void:
	var was_welcomed: bool = _links[peer]["welcomed"]
	_links.erase(peer)
	transport.disconnect_peer(peer)
	if not was_welcomed:
		return
	var last_tick := ack(peer, local_peer_id)
	_names.erase(peer)
	_acks.erase(peer)
	for o: int in _acks:
		(_acks[o] as Dictionary).erase(peer)
	time_sync.remove_peer(peer)
	_broadcast(Protocol.encode_drop(peer, last_tick, reason))
	peer_left.emit(peer, reason, last_tick)
	peers_changed.emit()


func _end(reason: int) -> void:
	transport.close()
	_links.clear()
	state = State.CLOSED
	session_ended.emit(reason)


func _on_packet(peer: int, channel: int, data: PackedByteArray) -> void:
	var link: Dictionary = _links.get(peer, {})
	var msg := Protocol.decode(data, channel)
	if link.is_empty() or msg.is_empty():
		dropped_packets += 1
		return
	var type: int = msg["type"]
	if Protocol.is_host_only(type) and (is_host() or peer != Transport.HOST_PEER):
		dropped_packets += 1
		return
	var welcomed_link: bool = link["welcomed"]
	if not welcomed_link and not type in (_HOST_PRE_HANDSHAKE if is_host() else _GUEST_PRE_HANDSHAKE):
		dropped_packets += 1
		return
	if msg.has("sender") and msg["sender"] != peer:
		dropped_packets += 1
		return
	link["last_heard"] = _frame
	match type:
		Protocol.Type.HELLO:
			if is_host() and not welcomed_link:
				_on_hello(peer, msg)
			else:
				dropped_packets += 1
		Protocol.Type.WELCOME:
			_on_welcome(msg)
		Protocol.Type.REJECT:
			rejected.emit(msg["reason"], msg["detail"])
			_end(msg["reason"])
		Protocol.Type.PEERS:
			_set_names(msg["peers"])
		Protocol.Type.LOBBY_REQ:
			if is_host():
				lobby_request_received.emit(peer, msg["req"])
			else:
				dropped_packets += 1
		Protocol.Type.LOBBY_STATE:
			lobby_state = msg["lobby"]
			lobby_state_received.emit(msg["lobby"])
		Protocol.Type.MATCH_START:
			match_start_received.emit(msg["config"], msg["seed"], msg["start"])
		Protocol.Type.CMD:
			command_received.emit(msg["cmd"])
		Protocol.Type.DROP:
			_on_drop(msg)
		Protocol.Type.BYE:
			_on_link_lost(peer, Protocol.Reason.LEFT if is_host() else msg["reason"])
		Protocol.Type.RESYNC:
			resync_received.emit(msg["tick"], msg["snapshot"])
		Protocol.Type.SNAPSHOT:
			snapshot_received.emit(msg["tick"], msg["snapshot"], msg["extra"])
		Protocol.Type.INPUT:
			_on_input(peer, msg)
		Protocol.Type.INPUT_ACK:
			if not in_match():
				return
			for origin: int in msg["acks"]:
				_set_ack(origin, peer, msg["acks"][origin])
		Protocol.Type.PING:
			_send(peer, Protocol.encode_pong(local_peer_id, msg["time_ms"], local_tick))
			_time_sample(peer, msg["tick"])
		Protocol.Type.PONG:
			_on_pong(peer, msg)
		Protocol.Type.HASH:
			hash_received.emit(peer, msg["tick"], msg["hash"])


func _on_hello(peer: int, msg: Dictionary) -> void:
	var reason := Protocol.Reason.NONE
	var detail := ""
	var nm := sanitize_name(msg["name"])
	if msg["protocol_version"] != identity["protocol_version"] \
			or msg["engine_version"] != identity["engine_version"] \
			or msg["game_build"] != identity["game_build"]:
		reason = Protocol.Reason.VERSION
		detail = "host: Godot %s, build %s, protocol %d / you: Godot %s, build %s, protocol %d" % [
			_engine_str(identity["engine_version"]), identity["game_build"], identity["protocol_version"],
			_engine_str(msg["engine_version"]), msg["game_build"], msg["protocol_version"]]
	elif msg["content_hash"] != identity["content_hash"]:
		reason = Protocol.Reason.CONTENT
		detail = "game data differs from the host's"
	elif not accepting_joins:
		reason = Protocol.Reason.IN_PROGRESS
	elif link_peers().size() >= max_guests:
		reason = Protocol.Reason.ROOM_FULL
	elif nm.is_empty():
		reason = Protocol.Reason.BAD_NAME
	if reason != Protocol.Reason.NONE:
		_send(peer, Protocol.encode_reject(reason, detail))
		_links.erase(peer)
		transport.disconnect_peer(peer)
		return
	var link: Dictionary = _links[peer]
	link["welcomed"] = true
	link["next_ping"] = _frame
	link["token"] = Crypto.new().generate_random_bytes(TOKEN_BYTES).hex_encode()
	_names[peer] = nm
	_send(peer, Protocol.encode_welcome(peer, link["token"], lobby_state, _names))
	for other in link_peers():
		if other != peer:
			_send(other, Protocol.encode_peers(_names))
	peer_joined.emit(peer, nm)
	peers_changed.emit()


func _on_welcome(msg: Dictionary) -> void:
	if is_host() or state != State.CONNECTING:
		return
	local_peer_id = msg["peer_id"]
	reconnect_token = msg["reconnect_token"]
	lobby_state = msg["lobby"]
	state = State.CONNECTED
	_links[Transport.HOST_PEER]["welcomed"] = true
	_set_names(msg["peers"])
	welcomed.emit(local_peer_id)
	lobby_state_received.emit(lobby_state)


func _set_names(peers: Dictionary) -> void:
	var old := _names.duplicate()
	_names = peers.duplicate()
	_names[local_peer_id] = local_name
	for p: int in _names:
		if not old.has(p) and p != local_peer_id:
			peer_joined.emit(p, _names[p])
	peers_changed.emit()


func _on_drop(msg: Dictionary) -> void:
	var peer: int = msg["peer"]
	if peer == local_peer_id or not _names.has(peer):
		return
	_names.erase(peer)
	time_sync.remove_peer(peer)
	peer_left.emit(peer, msg["reason"], msg["last_tick"])
	peers_changed.emit()


func _on_input(peer: int, msg: Dictionary) -> void:
	var origin: int = msg["origin"]
	if origin == local_peer_id or (is_host() and origin != peer):
		dropped_packets += 1
		return
	if not in_match():
		return  # the other side is still on a match we left
	_set_ack(local_peer_id, origin, msg["ack"])
	for s: Dictionary in msg["slots"]:
		var slot: int = s["slot"]
		if slot_owner(slot) != origin:
			continue
		var first: int = s["first_tick"]
		var frames: Array = s["frames"]
		var earliest := -1
		for i in frames.size():
			var tick := first + i
			if history.is_confirmed(slot, tick):
				continue
			var t := history.add_confirmed(slot, tick, frames[i])
			if t >= 0 and (earliest < 0 or t < earliest):
				earliest = t
			if history.is_confirmed(slot, tick):
				input_received.emit(origin, slot, tick, history.confirmed_frame(slot, tick))
		if earliest >= 0:
			mispredicted.emit(slot, earliest)


func _on_pong(peer: int, msg: Dictionary) -> void:
	var rtt := float((_now_ms_u32() - int(msg["echo_time_ms"])) & Protocol.U32_MAX)
	var s: Array = _links[peer]["rtt"]
	s.append(rtt)
	while s.size() > Tuning.net.rtt_samples:
		s.pop_front()
	rtt_updated.emit(peer, rtt_ms(peer))
	_time_sample(peer, msg["tick"])


func _time_sample(peer: int, remote_tick: int) -> void:
	var rtt := rtt_ms(peer)
	if rtt < 0.0 or local_tick <= 0 or remote_tick <= 0:
		return
	time_sync.add_sample(peer, local_tick, remote_tick, rtt / (1000.0 / Tuning.match_rules.tick_rate))


# --- sending ------------------------------------------------------------------

## Frames per slot per INPUT to `dest`: the spec's max_rollback_frames +
## input_delay_max, plus the frames still in flight over that link's round
## trip (an ack is always one RTT stale, so without them a high-ping link
## could never carry the newest frames), within u8 and the packet cap.
func redundancy_cap(dest: int) -> int:
	var cap := Tuning.net.max_rollback_frames + Tuning.net.input_delay_max
	var rtt := rtt_ms(dest)
	if rtt > 0.0:
		cap += ceili(rtt / (1000.0 / Tuning.match_rules.tick_rate))
	var per_slot_room := (Tuning.net.max_packet_bytes - Protocol.INPUT_HEADER) / maxi(_slot_owner.size(), 1) \
		- Protocol.INPUT_SLOT_HEADER
	return clampi(cap, 1, mini(Protocol.U8_MAX, per_slot_room / InputFrame.WIRE_SIZE))


func _send_inputs(dest: int) -> void:
	var cap := redundancy_cap(dest)
	var origins: Array[int] = []
	if is_host():
		for o in _origins():
			if o != dest:
				origins.append(o)
	else:
		origins.append(local_peer_id)
	for o in origins:
		var slots := slots_of(o)
		if slots.is_empty():
			continue
		var acked := ack(o, dest)
		if origin_confirmed_tick(o) <= acked:
			continue
		var payload: Array = []
		for slot in slots:
			payload.append({"slot": slot, "first_tick": acked + 1,
				"frames": history.frames_since(slot, acked, cap)})
		_send(dest, Protocol.encode_input(o, ack(dest, o), payload))


func _send_acks(dest: int) -> void:
	var acks := {}
	for o in _origins():
		if o != local_peer_id:
			acks[o] = ack(o, local_peer_id)
	if not acks.is_empty():
		_send(dest, Protocol.encode_input_ack(local_peer_id, acks))


## Peers owning at least one slot, sorted.
func _origins() -> Array[int]:
	var out: Array[int] = []
	for s: int in _slot_owner:
		var p: int = _slot_owner[s]
		if not out.has(p):
			out.append(p)
	out.sort()
	return out


func _set_ack(origin: int, dest: int, tick: int) -> void:
	if dest == local_peer_id:
		return  # our own acks come from history
	if not _acks.has(origin):
		_acks[origin] = {}
	var d: Dictionary = _acks[origin]
	d[dest] = maxi(d.get(dest, history.first_tick - 1), tick)


func _send(peer: int, bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		push_warning("Session: message too large or invalid, not sent")
		return false
	transport.send(peer, Protocol.channel_of(bytes[0]), bytes)
	return true


func _broadcast(bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		push_warning("Session: message too large or invalid, not sent")
		return false
	for p in link_peers():
		transport.send(p, Protocol.channel_of(bytes[0]), bytes)
	return true


func _now_ms_u32() -> int:
	var now: float = clock.call() if clock.is_valid() else Time.get_ticks_usec() * MS_PER_USEC
	return int(now) & Protocol.U32_MAX


static func _engine_str(hex: int) -> String:
	const BYTE := 8
	const MASK := 0xFF
	return "%d.%d.%d" % [(hex >> (BYTE * 2)) & MASK, (hex >> BYTE) & MASK, hex & MASK]
