class_name SignalingChannel
extends RefCounted
## One client's connection to a signaling server (docs/web_online.md,
## "Signaling protocol (v1)"). Abstract: SignalingClient (WebSocket, the real
## server) and LocalSignaling's endpoints (in-process twin, tests).
## WebRtcTransport drives it; nothing else needs to.
##
## Usage, once per frame: `poll()` and handle every message. Messages are the
## protocol's JSON objects as Dictionaries ({"op": String, ...}), plus two
## synthetic ones: {"op": OP_OPEN} once the socket is up and {"op": OP_CLOSED,
## "text": String} once it is gone (after it nothing more arrives; `text`
## says why, user-facing). `send()` before the socket is open queues the
## message until it opens. `close()` closes it without an OP_CLOSED.

const OP_OPEN := "_open"
const OP_CLOSED := "_closed"


## Every message received since the last call, in arrival order.
func poll() -> Array[Dictionary]:
	return []


## Send `msg` ({"op": ..., ...}); queued until the socket is open, dropped
## once it is closed.
func send(_msg: Dictionary) -> void:
	pass


func close() -> void:
	pass


func is_open() -> bool:
	return false


## True until OP_CLOSED was delivered or close() was called.
func is_alive() -> bool:
	return false
