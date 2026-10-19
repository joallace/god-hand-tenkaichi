class_name LoopbackNetwork
extends RefCounted
## In-process "internet" for LoopbackTransport endpoints (tests, net sims).
##
## Deterministic: time only moves on `advance_frame()` (one sim frame at
## `Tuning.match_rules.tick_rate`), and loss/jitter/duplication draw from one
## seeded RandomNumberGenerator, so a test replays exactly.
##
## Conditions (defaults below, or per direction with `set_conditions`):
## one-way `latency_ms` plus a uniform 0..`jitter_ms` extra per packet;
## `loss_percent` / `duplicate_percent` apply to the UNRELIABLE channel only.
## Reliable channels (and CONNECTED/DISCONNECTED) take the same delay but are
## never lost, duplicated or reordered (each one is held back behind the
## previous one on its link, like ENet's reliable sequencing). Jitter can
## reorder unreliable packets.
##
## Topology is free: `create_host()` + `connect_client()` builds the usual
## star (host numbers links from Transport.FIRST_GUEST_PEER, clients see the
## host as Transport.HOST_PEER); `link()` joins any two endpoints with chosen
## ids (mesh experiments, a rogue guest-to-guest link in tests).
##
## Failures: `set_silent(endpoint, true)` makes it drop everything it sends or
## would receive with no DISCONNECTED (pulled cable: only timeouts notice);
## `drop_link()` cuts a link and tells both sides (an ENet timeout);
## `LoopbackTransport.disconnect_peer()` / `close()` are graceful.
##
## Endpoints are referenced weakly (they own the network), so no cycles leak.

var latency_ms: float = 0.0
var jitter_ms: float = 0.0
var loss_percent: float = 0.0
var duplicate_percent: float = 0.0

## Sim frames advanced so far.
var frame: int = 0

## Counters for tests.
var sent_packets: int = 0
var lost_packets: int = 0
var duplicated_packets: int = 0

var rng := RandomNumberGenerator.new()

var _endpoints: Array[WeakRef] = []
## Pending deliveries: {"at": ms, "seq": int, "to": address, "peer": id at
## receiver, "uid": link uid, "event": Dictionary}.
var _in_flight: Array[Dictionary] = []
var _seq: int = 0
var _next_uid: int = 1
## "from:to" -> ms of the last ordered delivery on that direction.
var _ordered_at: Dictionary = {}
## "from:to" -> {latency_ms, jitter_ms, loss_percent, duplicate_percent}.
var _conditions: Dictionary = {}


func _init(seed_value: int = 0) -> void:
	rng.seed = seed_value


func frame_ms() -> float:
	return 1000.0 / Tuning.match_rules.tick_rate


## Current time in ms (frame-based). A Session's `clock` can point here.
func now_ms() -> float:
	return frame * frame_ms()


func create_host() -> LoopbackTransport:
	return _add_endpoint(true)


func create_client() -> LoopbackTransport:
	return _add_endpoint(false)


## Star link: the host gives the client its lowest free guest id. Both sides
## get CONNECTED after the one-way latency. Returns the client's id at the
## host (Transport.NO_PEER if the host is full).
func connect_client(client: LoopbackTransport, host: LoopbackTransport) -> int:
	var id := Transport.lowest_free_peer_id(host._links)
	if id == Transport.NO_PEER:
		return id
	link(host, client, id, Transport.HOST_PEER)
	return id


## Join two endpoints: `a` will call `b` peer `b_id_at_a`, and `b` will call
## `a` peer `a_id_at_b`. Both get CONNECTED after the one-way latency.
func link(a: LoopbackTransport, b: LoopbackTransport, b_id_at_a: int, a_id_at_b: int) -> void:
	var uid := _next_uid
	_next_uid += 1
	a._links[b_id_at_a] = {"remote": b.address, "remote_id": a_id_at_b, "uid": uid}
	b._links[a_id_at_b] = {"remote": a.address, "remote_id": b_id_at_a, "uid": uid}
	_schedule_ordered(a.address, b.address, a_id_at_b, uid,
		Transport.make_event(Transport.EventType.CONNECTED, a_id_at_b))
	_schedule_ordered(b.address, a.address, b_id_at_a, uid,
		Transport.make_event(Transport.EventType.CONNECTED, b_id_at_a))


## Abrupt link loss seen by both sides (after the one-way latency each way).
func drop_link(a: LoopbackTransport, peer_at_a: int) -> void:
	var l: Dictionary = a._links.get(peer_at_a, {})
	if l.is_empty():
		return
	_schedule_ordered(a.address, l["remote"], l["remote_id"], l["uid"],
		Transport.make_event(Transport.EventType.DISCONNECTED, l["remote_id"]))
	_schedule_ordered(l["remote"], a.address, peer_at_a, l["uid"],
		Transport.make_event(Transport.EventType.DISCONNECTED, peer_at_a))


## A silent endpoint drops everything it sends and everything sent to it.
func set_silent(endpoint: LoopbackTransport, silent: bool) -> void:
	endpoint.silent = silent


## Override conditions for packets going from `from` to `to`.
func set_conditions(from: LoopbackTransport, to: LoopbackTransport, latency: float,
		jitter: float = 0.0, loss: float = 0.0, duplicate: float = 0.0) -> void:
	_conditions["%d:%d" % [from.address, to.address]] = {
		"latency_ms": latency, "jitter_ms": jitter,
		"loss_percent": loss, "duplicate_percent": duplicate,
	}


## Move time forward and deliver everything due by then.
func advance_frame(frames: int = 1) -> void:
	for i in frames:
		frame += 1
		_deliver_due()


func in_flight_count() -> int:
	return _in_flight.size()


# --- used by LoopbackTransport ------------------------------------------------

func _send(from: LoopbackTransport, peer: int, channel: int, bytes: PackedByteArray) -> void:
	var l: Dictionary = from._links.get(peer, {})
	if l.is_empty():
		return
	sent_packets += 1
	if from.silent:
		lost_packets += 1
		return
	var ev := Transport.make_event(Transport.EventType.PACKET, l["remote_id"], channel, bytes.duplicate())
	if channel != Transport.Channel.UNRELIABLE:
		_schedule_ordered(from.address, l["remote"], l["remote_id"], l["uid"], ev)
		return
	var c := _cond(from.address, l["remote"])
	if rng.randf() * 100.0 < c["loss_percent"]:
		lost_packets += 1
		return
	_schedule(_delay(c), l["remote"], l["remote_id"], l["uid"], ev)
	if rng.randf() * 100.0 < c["duplicate_percent"]:
		duplicated_packets += 1
		_schedule(_delay(c), l["remote"], l["remote_id"], l["uid"], ev.duplicate(true))


## Graceful close of `from`'s link `peer`: the far side gets DISCONNECTED
## after anything reliable already queued.
func _disconnect(from: LoopbackTransport, peer: int) -> void:
	var l: Dictionary = from._links.get(peer, {})
	if l.is_empty():
		return
	from._links.erase(peer)
	if from.silent:
		return
	_schedule_ordered(from.address, l["remote"], l["remote_id"], l["uid"],
		Transport.make_event(Transport.EventType.DISCONNECTED, l["remote_id"]))


# --- internals ----------------------------------------------------------------

func _add_endpoint(host: bool) -> LoopbackTransport:
	var t := LoopbackTransport.new(self, _endpoints.size(), host)
	_endpoints.append(weakref(t))
	return t


func _endpoint(address: int) -> LoopbackTransport:
	if address < 0 or address >= _endpoints.size():
		return null
	return _endpoints[address].get_ref() as LoopbackTransport


func _cond(from_address: int, to_address: int) -> Dictionary:
	return _conditions.get("%d:%d" % [from_address, to_address], {
		"latency_ms": latency_ms, "jitter_ms": jitter_ms,
		"loss_percent": loss_percent, "duplicate_percent": duplicate_percent,
	})


func _delay(c: Dictionary) -> float:
	return c["latency_ms"] + rng.randf_range(0.0, c["jitter_ms"])


## Reliable lane: never earlier than the previous ordered delivery on the
## same direction, so reliable packets and link events keep their order.
func _schedule_ordered(from_address: int, to_address: int, peer: int, uid: int, ev: Dictionary) -> void:
	var key := "%d:%d" % [from_address, to_address]
	var at := maxf(now_ms() + _delay(_cond(from_address, to_address)), _ordered_at.get(key, 0.0))
	_ordered_at[key] = at
	_schedule(at - now_ms(), to_address, peer, uid, ev)


func _schedule(delay_ms: float, to_address: int, peer: int, uid: int, ev: Dictionary) -> void:
	_seq += 1
	_in_flight.append({"at": now_ms() + delay_ms, "seq": _seq, "to": to_address,
		"peer": peer, "uid": uid, "event": ev})


func _deliver_due() -> void:
	var now := now_ms()
	var due: Array[Dictionary] = []
	var keep: Array[Dictionary] = []
	for p in _in_flight:
		if p["at"] <= now:
			due.append(p)
		else:
			keep.append(p)
	_in_flight = keep
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["at"] < b["at"] or (a["at"] == b["at"] and a["seq"] < b["seq"]))
	for p in due:
		var to := _endpoint(p["to"])
		if to == null or to.closed:
			continue
		if to.silent:
			lost_packets += 1
			continue
		var l: Dictionary = to._links.get(p["peer"], {})
		if l.is_empty() or l["uid"] != p["uid"]:
			continue  # link gone (or replaced) while in flight
		var ev: Dictionary = p["event"]
		if ev["type"] == Transport.EventType.DISCONNECTED:
			to._links.erase(p["peer"])
		to._inbox.append(ev)
