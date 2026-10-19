class_name LoopbackTransport
extends Transport
## In-process Transport endpoint on a shared LoopbackNetwork (which simulates
## latency, jitter, loss and failures; see there). Create endpoints with
## `network.create_host()` / `network.create_client()`, then
## `network.connect_client(client, host)` (or `network.link`). Events arrive
## only when the network's clock advances (`network.advance_frame()`).

var network: LoopbackNetwork
## Index of this endpoint on the network.
var address: int = -1
## Set through `network.set_silent()`.
var silent := false
var closed := false

var _host := false
## peer id -> {"remote": address, "remote_id": int, "uid": int}
var _links: Dictionary = {}
var _inbox: Array[Dictionary] = []


func _init(net: LoopbackNetwork, addr: int, host: bool) -> void:
	network = net
	address = addr
	_host = host


func send(peer: int, channel: int, bytes: PackedByteArray) -> void:
	if closed or channel < 0 or channel >= CHANNEL_COUNT:
		return
	network._send(self, peer, channel, bytes)


func poll() -> Array[Dictionary]:
	var out := _inbox
	_inbox = []
	return out


func disconnect_peer(peer: int) -> void:
	network._disconnect(self, peer)


func close() -> void:
	if closed:
		return
	for peer: int in _links.keys():
		network._disconnect(self, peer)
	closed = true
	_inbox.clear()


func is_host() -> bool:
	return _host


func connected_peers() -> Array[int]:
	var out: Array[int] = []
	for peer: int in _links:
		out.append(peer)
	out.sort()
	return out
