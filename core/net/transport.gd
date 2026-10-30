class_name Transport
extends RefCounted
## Packet pipe between this machine and its link peers (SPEC_ONLINE.md §4, §5.1).
## Abstract: EnetTransport (UDP) and LoopbackTransport (in-process, tests).
##
## Peer ids name LINKS, and the host's session layer reuses them as session
## peer ids: the host is always `HOST_PEER` (1); a host transport numbers each
## accepted link with the lowest free id >= `FIRST_GUEST_PEER`; a client
## transport sees its single link (to the host) as `HOST_PEER`. A client
## learns its own id from the session's WELCOME, so `local_peer_id()` is
## `HOST_PEER` on a host and `NO_PEER` on a client.
##
## Usage, once per frame: `poll()` and handle every event, queue `send()`s,
## then `flush()` so they leave this frame. Bytes passed to `send` are copied.
##
## Events are Dictionaries: {"type": EventType, "peer": int, "channel": int,
## "data": PackedByteArray} (channel/data only meaningful for PACKET).

## SPEC_ONLINE.md §5.1. UNRELIABLE may be lost, duplicated or reordered;
## RELIABLE and BULK arrive once, in order (per channel), or the link drops.
enum Channel { UNRELIABLE = 0, RELIABLE = 1, BULK = 2 }
const CHANNEL_COUNT := 3

enum EventType { CONNECTED, DISCONNECTED, PACKET }

const NO_PEER := 0
const HOST_PEER := 1
const FIRST_GUEST_PEER := 2
## Peer ids travel as u8 (Protocol), so a host never numbers links past this.
const MAX_PEER_ID := 255


## Queue `bytes` for `peer` on `channel`. Unknown peers are ignored.
func send(_peer: int, _channel: int, _bytes: PackedByteArray) -> void:
	pass


## Every event that happened since the last call, in arrival order.
func poll() -> Array[Dictionary]:
	return []


## Push queued packets out now (no-op where sends are immediate).
func flush() -> void:
	pass


## Drop one link. The far side gets DISCONNECTED once queued reliable packets
## have been delivered; this side gets no event (it asked for it).
func disconnect_peer(_peer: int) -> void:
	pass


## Drop every link (best effort delivery of what is queued) and release the
## socket. No events afterwards.
func close() -> void:
	pass


func is_host() -> bool:
	return false


func local_peer_id() -> int:
	return HOST_PEER if is_host() else NO_PEER


## Client: frames this transport may take to connect (or report the failure
## as DISCONNECTED for HOST_PEER) on its own; a Session waits at least this
## long before giving up. 0 = no opinion.
func connect_timeout_frames() -> int:
	return 0


## Ids of the currently connected link peers.
func connected_peers() -> Array[int]:
	return []


static func make_event(type: EventType, peer: int, channel: int = 0,
		data: PackedByteArray = PackedByteArray()) -> Dictionary:
	return {"type": type, "peer": peer, "channel": channel, "data": data}


## Lowest id >= FIRST_GUEST_PEER not a key of `used` (a host's next link id),
## or NO_PEER when every id up to MAX_PEER_ID is taken.
static func lowest_free_peer_id(used: Dictionary) -> int:
	for id in range(FIRST_GUEST_PEER, MAX_PEER_ID + 1):
		if not used.has(id):
			return id
	return NO_PEER
