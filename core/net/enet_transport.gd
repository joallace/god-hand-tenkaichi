class_name EnetTransport
extends Transport
## Transport over a raw ENetConnection (UDP; no MultiplayerAPI, no @rpc).
## Channels map 1:1 to Transport.Channel: UNRELIABLE is sent unsequenced
## (Protocol tolerates loss/reordering), RELIABLE and BULK reliable-ordered.
##
## Host: `var t := EnetTransport.new(); t.host(port, max_peers)`; accepted
## links get ids from Transport.FIRST_GUEST_PEER up (lowest free).
## Client: `t.join(address_text, default_port)`; the host link is
## Transport.HOST_PEER and CONNECTED arrives once ENet's handshake completes
## (a failed attempt ends in DISCONNECTED for HOST_PEER).
##
## `parse_address()` accepts `IP:PORT`, `IP`, `hostname[:PORT]` and
## `[IPv6]:PORT` / `[IPv6]` / bare IPv6, with the default port if omitted.

## Accept from every interface (ENet binds dual-stack where available).
const BIND_ANY := "*"
const MAX_PORT := 65535
## DNS limits (RFC 1035): whole name and one label.
const HOSTNAME_MAX_LEN := 253
const LABEL_MAX_LEN := 63

var _conn: ENetConnection = null
var _host := false
## id -> ENetPacketPeer, and ENetPacketPeer instance id -> id.
var _peers: Dictionary = {}
var _ids: Dictionary = {}


## Bind `port` and accept up to `max_peers` links. Returns an Error
## (ERR_CANT_CREATE when the port is in use).
func host(port: int, max_peers: int, bind_address: String = BIND_ANY) -> Error:
	close()
	_conn = ENetConnection.new()
	var err := _conn.create_host_bound(bind_address, port,
		mini(max_peers, MAX_PEER_ID - FIRST_GUEST_PEER + 1), CHANNEL_COUNT)
	if err != OK:
		_conn = null
		return err
	_host = true
	return OK


## Start connecting to `address_text` (see parse_address). Returns an Error
## (ERR_INVALID_PARAMETER for an unparsable address, ERR_CANT_RESOLVE for an
## unknown hostname). Hostname lookup blocks; resolve on a thread first if
## that matters (IP.resolve_hostname_queue_item).
func join(address_text: String, default_port: int) -> Error:
	close()
	var a := parse_address(address_text, default_port)
	if not a["ok"]:
		return ERR_INVALID_PARAMETER
	var ip: String = a["host"]
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(ip)
		if ip.is_empty():
			return ERR_CANT_RESOLVE
	_conn = ENetConnection.new()
	var err := _conn.create_host(1, CHANNEL_COUNT)
	if err != OK:
		_conn = null
		return err
	var peer := _conn.connect_to_host(ip, a["port"], CHANNEL_COUNT)
	if peer == null:
		_conn.destroy()
		_conn = null
		return ERR_CANT_CONNECT
	_host = false
	_map(HOST_PEER, peer)
	return OK


## The bound port (host) or the local port in use (client); 0 when closed.
func local_port() -> int:
	return _conn.get_local_port() if _conn else 0


func send(peer: int, channel: int, bytes: PackedByteArray) -> void:
	var p: ENetPacketPeer = _peers.get(peer)
	if p == null or channel < 0 or channel >= CHANNEL_COUNT:
		return
	var flags := ENetPacketPeer.FLAG_UNSEQUENCED if channel == Channel.UNRELIABLE \
		else ENetPacketPeer.FLAG_RELIABLE
	p.send(channel, bytes, flags)


func poll() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _conn == null:
		return out
	while true:
		var ev: Array = _conn.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE or type == ENetConnection.EVENT_ERROR:
			break
		var peer: ENetPacketPeer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				var id := HOST_PEER
				if _host:
					id = lowest_free_peer_id(_peers)
					if id == NO_PEER:
						peer.peer_disconnect_now()
						continue
					_map(id, peer)
				elif not _ids.has(peer.get_instance_id()):
					continue
				out.append(make_event(EventType.CONNECTED, id))
			ENetConnection.EVENT_DISCONNECT:
				var id: int = _ids.get(peer.get_instance_id(), NO_PEER)
				if id != NO_PEER:
					_unmap(id)
					out.append(make_event(EventType.DISCONNECTED, id))
			ENetConnection.EVENT_RECEIVE:
				var data := peer.get_packet()
				var id: int = _ids.get(peer.get_instance_id(), NO_PEER)
				if id != NO_PEER:
					out.append(make_event(EventType.PACKET, id, ev[3], data))
	return out


func flush() -> void:
	if _conn:
		_conn.flush()


func disconnect_peer(peer: int) -> void:
	var p: ENetPacketPeer = _peers.get(peer)
	if p == null:
		return
	_unmap(peer)
	p.peer_disconnect_later()


func close() -> void:
	if _conn == null:
		return
	for id: int in _peers.keys():
		(_peers[id] as ENetPacketPeer).peer_disconnect_later()
	_conn.flush()
	_conn.destroy()
	_conn = null
	_peers.clear()
	_ids.clear()


func is_host() -> bool:
	return _host


func connected_peers() -> Array[int]:
	var out: Array[int] = []
	for id: int in _peers:
		var p: ENetPacketPeer = _peers[id]
		if p.get_state() == ENetPacketPeer.STATE_CONNECTED:
			out.append(id)
	out.sort()
	return out


## Round-trip time ENet measures for a link, in ms (-1 if unknown).
func enet_rtt_ms(peer: int) -> float:
	var p: ENetPacketPeer = _peers.get(peer)
	return p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) if p else -1.0


## Packet loss ENet measures for a link, in percent (-1 if unknown).
func packet_loss(peer: int) -> float:
	const PERCENT := 100.0
	var p: ENetPacketPeer = _peers.get(peer)
	return p.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) * PERCENT / ENetPacketPeer.PACKET_LOSS_SCALE if p else -1.0


func _map(id: int, peer: ENetPacketPeer) -> void:
	_peers[id] = peer
	_ids[peer.get_instance_id()] = id


func _unmap(id: int) -> void:
	var p: ENetPacketPeer = _peers.get(id)
	if p:
		_ids.erase(p.get_instance_id())
	_peers.erase(id)


## Split a join-screen address. Returns {"ok": bool, "host": String,
## "port": int, "error": String}. Accepts `1.2.3.4:7777`, `1.2.3.4`,
## `example.org`, `example.org:7777`, `[::1]:7777`, `[::1]` and bare `::1`
## (more than one ':' without brackets = IPv6 with no port).
static func parse_address(text: String, default_port: int) -> Dictionary:
	var s := text.strip_edges()
	var host_part := s
	var port_text := ""
	if s.is_empty():
		return _address_error("empty address")
	if s.begins_with("["):
		var close_at := s.find("]")
		if close_at < 0:
			return _address_error("missing ']'")
		host_part = s.substr(1, close_at - 1)
		var rest := s.substr(close_at + 1)
		if not rest.is_empty():
			if not rest.begins_with(":"):
				return _address_error("unexpected text after ']'")
			port_text = rest.substr(1)
			if port_text.is_empty():
				return _address_error("missing port")
		if not host_part.is_valid_ip_address() or host_part.count(":") == 0:
			return _address_error("not an IPv6 address")
	elif s.count(":") == 1:
		var colon := s.find(":")
		host_part = s.substr(0, colon)
		port_text = s.substr(colon + 1)
		if port_text.is_empty():
			return _address_error("missing port")
	elif s.count(":") > 1:
		if not s.is_valid_ip_address():
			return _address_error("not an IPv6 address")
	if host_part.is_empty():
		return _address_error("missing host")
	if not host_part.is_valid_ip_address() and not _is_hostname(host_part):
		return _address_error("invalid host name")
	var port := default_port
	if not port_text.is_empty():
		if not port_text.is_valid_int():
			return _address_error("invalid port")
		port = port_text.to_int()
	if port < 1 or port > MAX_PORT:
		return _address_error("port out of range")
	return {"ok": true, "host": host_part, "port": port, "error": ""}


static func _address_error(msg: String) -> Dictionary:
	return {"ok": false, "host": "", "port": 0, "error": msg}


## RFC 1123-ish: dot-separated labels of ASCII letters, digits and '-', not
## starting or ending with '-'.
static func _is_hostname(h: String) -> bool:
	if h.length() > HOSTNAME_MAX_LEN:
		return false
	for label in h.split("."):
		if label.is_empty() or label.length() > LABEL_MAX_LEN or label.begins_with("-") or label.ends_with("-"):
			return false
		for c in label:
			var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-"
			if not ok:
				return false
	return true
