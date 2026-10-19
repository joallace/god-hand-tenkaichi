class_name Protocol
extends RefCounted
## Wire messages (SPEC_ONLINE.md §5). Static encode/decode only; no state.
##
## Every message starts with a 1-byte `Type`. Layouts:
## - Hot (channel 0), fixed little-endian:
##   INPUT     origin:u8 ack_tick_from_dest:u32 slot_count:u8
##             slot_count × { slot:u8 first_tick:u32 count:u8 count × frame }
##             (frame = InputFrame wire bytes, InputFrame.WIRE_SIZE each)
##   INPUT_ACK sender:u8 n:u8 n × { origin:u8 tick:u32 }
##   PING      sender:u8 time_ms:u32 tick:u32
##   PONG      sender:u8 echo_time_ms:u32 tick:u32
##   HASH      sender:u8 tick:u32 hash:i64
## - Reliable (channel 1): type + var_to_bytes(Dictionary of the fields).
## - Bulk (channel 2): type + raw_size:u32 + zstd(var_to_bytes(fields)).
## Dictionaries are decoded with `bytes_to_var` (never the `_with_objects`
## variant) and each field is type-checked; payloads such as `lobby`,
## `config`, `cmd` and `snapshot` are opaque Dictionaries to this layer.
##
## `decode(bytes, channel)` returns {"type": Type, ...fields} or an EMPTY
## Dictionary for anything malformed: unknown type, wrong channel for the
## type, truncated/trailing bytes, out-of-range values, oversize (channels
## 0/1 over Tuning.net.max_packet_bytes, bulk over Tuning.net.max_bulk_bytes,
## raw or compressed). Encoders return an empty PackedByteArray when the
## message would be rejected by `decode` (e.g. too big), so check `is_empty()`.
##
## Decoded field names (and the encoder's arguments):
##   INPUT       origin, ack, slots: [{slot, first_tick, frames: Array[InputFrame]}]
##   INPUT_ACK   sender, acks: {origin: tick}
##   PING        sender, time_ms, tick        PONG  sender, echo_time_ms, tick
##   HASH        sender, tick, hash
##   HELLO       protocol_version, engine_version, game_build, content_hash,
##               name, reconnect_token ("" = none)
##   WELCOME     peer_id, reconnect_token, lobby, peers: {peer_id: name}
##   REJECT      reason (Reason), detail
##   LOBBY_STATE lobby                        PEERS peers: {peer_id: name}
##   MATCH_START config, seed, start (opaque start info)
##   CMD         cmd ({"tick": int, "kind": int, ...})
##   DROP        peer, last_tick, reason      BYE   reason
##   RESYNC      tick, snapshot               SNAPSHOT tick, snapshot, extra

## Bump on any wire change; HELLO carries it.
const PROTOCOL_VERSION := 1

enum Type {
	# hot, channel 0
	INPUT = 1, INPUT_ACK = 2, PING = 3, PONG = 4, HASH = 5,
	# reliable, channel 1
	HELLO = 16, WELCOME = 17, REJECT = 18, LOBBY_STATE = 19, PEERS = 20,
	MATCH_START = 21, CMD = 22, DROP = 23, BYE = 24,
	# bulk, channel 2
	RESYNC = 32, SNAPSHOT = 33,
}

## REJECT reasons (SPEC_ONLINE.md §5.3) and BYE/DROP reasons.
enum Reason {
	NONE = 0, VERSION = 1, CONTENT = 2, ROOM_FULL = 3, IN_PROGRESS = 4,
	BAD_NAME = 5, HOST_CLOSING = 6, PROTOCOL = 7,
	## BYE / DROP only
	LEFT = 16, TIMEOUT = 17, DISCONNECTED = 18,
	## BYE: the host ended the match after too many desync resyncs.
	DESYNC = 19,
}

const U8_MAX := 0xFF
const U32_MAX := 0xFFFFFFFF
const TYPE_BYTES := 1
const PEER_BYTES := 1
const TICK_BYTES := 4
const COUNT_BYTES := 1
const HASH_BYTES := 8
const SIZE_BYTES := 4
const INPUT_HEADER := TYPE_BYTES + PEER_BYTES + TICK_BYTES + COUNT_BYTES
const INPUT_SLOT_HEADER := COUNT_BYTES + TICK_BYTES + COUNT_BYTES
const ACK_HEADER := TYPE_BYTES + PEER_BYTES + COUNT_BYTES
const ACK_ENTRY := PEER_BYTES + TICK_BYTES
const PING_SIZE := TYPE_BYTES + PEER_BYTES + TICK_BYTES + TICK_BYTES
const HASH_SIZE := TYPE_BYTES + PEER_BYTES + TICK_BYTES + HASH_BYTES
const BULK_HEADER := TYPE_BYTES + SIZE_BYTES
## Byte offsets shared by the hot layouts: [type][peer][u32 ...].
const _PEER_AT := TYPE_BYTES
const _U32_AT := TYPE_BYTES + PEER_BYTES
const _AFTER_U32 := _U32_AT + TICK_BYTES

const _HOST_ONLY: Array[int] = [
	Type.WELCOME, Type.REJECT, Type.LOBBY_STATE, Type.PEERS, Type.MATCH_START,
	Type.CMD, Type.DROP, Type.RESYNC, Type.SNAPSHOT,
]

## Field name -> Variant type, per dictionary-encoded message.
const _SCHEMAS := {
	Type.HELLO: {"protocol_version": TYPE_INT, "engine_version": TYPE_INT,
		"game_build": TYPE_STRING, "content_hash": TYPE_STRING, "name": TYPE_STRING,
		"reconnect_token": TYPE_STRING},
	Type.WELCOME: {"peer_id": TYPE_INT, "reconnect_token": TYPE_STRING,
		"lobby": TYPE_DICTIONARY, "peers": TYPE_DICTIONARY},
	Type.REJECT: {"reason": TYPE_INT, "detail": TYPE_STRING},
	Type.LOBBY_STATE: {"lobby": TYPE_DICTIONARY},
	Type.PEERS: {"peers": TYPE_DICTIONARY},
	Type.MATCH_START: {"config": TYPE_DICTIONARY, "seed": TYPE_INT, "start": TYPE_DICTIONARY},
	Type.CMD: {"cmd": TYPE_DICTIONARY},
	Type.DROP: {"peer": TYPE_INT, "last_tick": TYPE_INT, "reason": TYPE_INT},
	Type.BYE: {"reason": TYPE_INT},
	Type.RESYNC: {"tick": TYPE_INT, "snapshot": TYPE_DICTIONARY},
	Type.SNAPSHOT: {"tick": TYPE_INT, "snapshot": TYPE_DICTIONARY, "extra": TYPE_DICTIONARY},
}


static func channel_of(type: int) -> int:
	if type >= Type.RESYNC:
		return Transport.Channel.BULK
	if type >= Type.HELLO:
		return Transport.Channel.RELIABLE
	return Transport.Channel.UNRELIABLE


## Messages only the host may send; a session drops them from anyone else.
static func is_host_only(type: int) -> bool:
	return type in _HOST_ONLY


static func is_known_type(type: int) -> bool:
	return Type.values().has(type)


# --- hot encoders ---------------------------------------------------------------

## `slots`: [{"slot": int, "first_tick": int, "frames": Array of InputFrame}].
static func encode_input(origin: int, ack: int, slots: Array) -> PackedByteArray:
	if not _peer_ok(origin) or not _tick_ok(ack) or slots.is_empty() \
			or slots.size() > Tuning.net.max_fighters:
		return PackedByteArray()
	var size := INPUT_HEADER
	for s: Dictionary in slots:
		var n: int = (s["frames"] as Array).size()
		if n < 1 or n > U8_MAX or not _u8_ok(s["slot"]) or not _tick_ok(s["first_tick"]) \
				or not _tick_ok(int(s["first_tick"]) + n - 1):
			return PackedByteArray()
		size += INPUT_SLOT_HEADER + n * InputFrame.WIRE_SIZE
	if size > Tuning.net.max_packet_bytes:
		return PackedByteArray()
	var b := PackedByteArray()
	b.resize(size)
	b.encode_u8(0, Type.INPUT)
	b.encode_u8(_PEER_AT, origin)
	b.encode_u32(_U32_AT, ack)
	b.encode_u8(_AFTER_U32, slots.size())
	var o := INPUT_HEADER
	for s: Dictionary in slots:
		var frames: Array = s["frames"]
		b.encode_u8(o, s["slot"])
		b.encode_u32(o + COUNT_BYTES, s["first_tick"])
		b.encode_u8(o + COUNT_BYTES + TICK_BYTES, frames.size())
		o += INPUT_SLOT_HEADER
		for f: InputFrame in frames:
			f.encode_into(b, o)
			o += InputFrame.WIRE_SIZE
	return b


## `acks`: {origin_peer: tick} = "sender has every frame of origin up to tick".
static func encode_input_ack(sender: int, acks: Dictionary) -> PackedByteArray:
	if not _peer_ok(sender) or acks.size() > U8_MAX:
		return PackedByteArray()
	var b := PackedByteArray()
	b.resize(ACK_HEADER + acks.size() * ACK_ENTRY)
	if b.size() > Tuning.net.max_packet_bytes:
		return PackedByteArray()
	b.encode_u8(0, Type.INPUT_ACK)
	b.encode_u8(_PEER_AT, sender)
	b.encode_u8(_U32_AT, acks.size())
	var o := ACK_HEADER
	for origin: Variant in acks:
		if not _peer_ok(origin) or not _tick_ok(acks[origin]):
			return PackedByteArray()
		b.encode_u8(o, origin)
		b.encode_u32(o + PEER_BYTES, acks[origin])
		o += ACK_ENTRY
	return b


static func encode_ping(sender: int, time_ms: int, tick: int) -> PackedByteArray:
	return _encode_ping_like(Type.PING, sender, time_ms, tick)


static func encode_pong(sender: int, echo_time_ms: int, tick: int) -> PackedByteArray:
	return _encode_ping_like(Type.PONG, sender, echo_time_ms, tick)


static func encode_hash(sender: int, tick: int, hash_value: int) -> PackedByteArray:
	if not _peer_ok(sender) or not _tick_ok(tick):
		return PackedByteArray()
	var b := PackedByteArray()
	b.resize(HASH_SIZE)
	b.encode_u8(0, Type.HASH)
	b.encode_u8(_PEER_AT, sender)
	b.encode_u32(_U32_AT, tick)
	b.encode_s64(_AFTER_U32, hash_value)
	return b


# --- reliable / bulk encoders ---------------------------------------------------

## `info` keys as in the HELLO schema; `protocol_version` and
## `reconnect_token` may be omitted.
static func encode_hello(info: Dictionary) -> PackedByteArray:
	var d := info.duplicate()
	if not d.has("reconnect_token"):
		d["reconnect_token"] = ""
	if not d.has("protocol_version"):
		d["protocol_version"] = PROTOCOL_VERSION
	return _encode_dict(Type.HELLO, d)


static func encode_welcome(peer_id: int, reconnect_token: String, lobby: Dictionary,
		peers: Dictionary) -> PackedByteArray:
	return _encode_dict(Type.WELCOME, {"peer_id": peer_id, "reconnect_token": reconnect_token,
		"lobby": lobby, "peers": peers})


static func encode_reject(reason: int, detail: String = "") -> PackedByteArray:
	return _encode_dict(Type.REJECT, {"reason": reason, "detail": detail})


static func encode_lobby_state(lobby: Dictionary) -> PackedByteArray:
	return _encode_dict(Type.LOBBY_STATE, {"lobby": lobby})


static func encode_peers(peers: Dictionary) -> PackedByteArray:
	return _encode_dict(Type.PEERS, {"peers": peers})


static func encode_match_start(config: Dictionary, seed_value: int, start: Dictionary = {}) -> PackedByteArray:
	return _encode_dict(Type.MATCH_START, {"config": config, "seed": seed_value, "start": start})


static func encode_cmd(cmd: Dictionary) -> PackedByteArray:
	return _encode_dict(Type.CMD, {"cmd": cmd})


static func encode_drop(peer: int, last_tick: int, reason: int) -> PackedByteArray:
	return _encode_dict(Type.DROP, {"peer": peer, "last_tick": last_tick, "reason": reason})


static func encode_bye(reason: int) -> PackedByteArray:
	return _encode_dict(Type.BYE, {"reason": reason})


static func encode_resync(tick: int, snapshot: Dictionary) -> PackedByteArray:
	return _encode_bulk(Type.RESYNC, {"tick": tick, "snapshot": snapshot})


static func encode_snapshot(tick: int, snapshot: Dictionary, extra: Dictionary = {}) -> PackedByteArray:
	return _encode_bulk(Type.SNAPSHOT, {"tick": tick, "snapshot": snapshot, "extra": extra})


# --- decode -------------------------------------------------------------------

static func decode(bytes: PackedByteArray, channel: int) -> Dictionary:
	if bytes.is_empty():
		return {}
	var cap: int = Tuning.net.max_bulk_bytes if channel == Transport.Channel.BULK \
		else Tuning.net.max_packet_bytes
	if bytes.size() > cap:
		return {}
	var type := bytes.decode_u8(0)
	if not is_known_type(type) or channel_of(type) != channel:
		return {}
	var msg: Dictionary
	match type:
		Type.INPUT:
			msg = _decode_input(bytes)
		Type.INPUT_ACK:
			msg = _decode_input_ack(bytes)
		Type.PING, Type.PONG:
			msg = _decode_ping_like(bytes, type)
		Type.HASH:
			msg = _decode_hash(bytes)
		_:
			var fields := _decode_bulk_fields(bytes) if channel == Transport.Channel.BULK \
				else _bytes_to_dict(bytes.slice(TYPE_BYTES))
			msg = _check_schema(type, fields)
	if not msg.is_empty():
		msg["type"] = type
	return msg


# --- internals ----------------------------------------------------------------

static func _u8_ok(v: Variant) -> bool:
	return typeof(v) == TYPE_INT and v >= 0 and v <= U8_MAX


static func _peer_ok(v: Variant) -> bool:
	return typeof(v) == TYPE_INT and v >= Transport.HOST_PEER and v <= Transport.MAX_PEER_ID


static func _tick_ok(v: Variant) -> bool:
	return typeof(v) == TYPE_INT and v >= 0 and v <= U32_MAX


static func _encode_ping_like(type: int, sender: int, time_ms: int, tick: int) -> PackedByteArray:
	if not _peer_ok(sender) or not _tick_ok(tick):
		return PackedByteArray()
	var b := PackedByteArray()
	b.resize(PING_SIZE)
	b.encode_u8(0, type)
	b.encode_u8(_PEER_AT, sender)
	b.encode_u32(_U32_AT, time_ms & U32_MAX)
	b.encode_u32(_AFTER_U32, tick)
	return b


static func _decode_input(b: PackedByteArray) -> Dictionary:
	if b.size() < INPUT_HEADER:
		return {}
	var origin := b.decode_u8(_PEER_AT)
	var n_slots := b.decode_u8(_AFTER_U32)
	if not _peer_ok(origin) or n_slots < 1 or n_slots > Tuning.net.max_fighters:
		return {}
	var slots: Array[Dictionary] = []
	var seen := {}
	var o := INPUT_HEADER
	for i in n_slots:
		if o + INPUT_SLOT_HEADER > b.size():
			return {}
		var slot := b.decode_u8(o)
		var first := b.decode_u32(o + COUNT_BYTES)
		var count := b.decode_u8(o + COUNT_BYTES + TICK_BYTES)
		o += INPUT_SLOT_HEADER
		if count < 1 or seen.has(slot) or first + count - 1 > U32_MAX \
				or o + count * InputFrame.WIRE_SIZE > b.size():
			return {}
		seen[slot] = true
		var frames: Array[InputFrame] = []
		for k in count:
			frames.append(InputFrame.decode_from(b, o))
			o += InputFrame.WIRE_SIZE
		slots.append({"slot": slot, "first_tick": first, "frames": frames})
	if o != b.size():
		return {}
	return {"origin": origin, "ack": b.decode_u32(_U32_AT), "slots": slots}


static func _decode_input_ack(b: PackedByteArray) -> Dictionary:
	if b.size() < ACK_HEADER:
		return {}
	var sender := b.decode_u8(_PEER_AT)
	var n := b.decode_u8(_U32_AT)
	if not _peer_ok(sender) or b.size() != ACK_HEADER + n * ACK_ENTRY:
		return {}
	var acks := {}
	for i in n:
		var o := ACK_HEADER + i * ACK_ENTRY
		var origin := b.decode_u8(o)
		if not _peer_ok(origin) or acks.has(origin):
			return {}
		acks[origin] = b.decode_u32(o + PEER_BYTES)
	return {"sender": sender, "acks": acks}


static func _decode_ping_like(b: PackedByteArray, type: int) -> Dictionary:
	if b.size() != PING_SIZE or not _peer_ok(b.decode_u8(_PEER_AT)):
		return {}
	var time_key := "time_ms" if type == Type.PING else "echo_time_ms"
	return {"sender": b.decode_u8(_PEER_AT), time_key: b.decode_u32(_U32_AT),
		"tick": b.decode_u32(_AFTER_U32)}


static func _decode_hash(b: PackedByteArray) -> Dictionary:
	if b.size() != HASH_SIZE or not _peer_ok(b.decode_u8(_PEER_AT)):
		return {}
	return {"sender": b.decode_u8(_PEER_AT), "tick": b.decode_u32(_U32_AT),
		"hash": b.decode_s64(_AFTER_U32)}


static func _encode_dict(type: int, fields: Dictionary) -> PackedByteArray:
	if _check_schema(type, fields).is_empty():
		return PackedByteArray()
	var b := PackedByteArray([type])
	b.append_array(var_to_bytes(fields))
	if b.size() > Tuning.net.max_packet_bytes:
		return PackedByteArray()
	return b


static func _encode_bulk(type: int, fields: Dictionary) -> PackedByteArray:
	if _check_schema(type, fields).is_empty():
		return PackedByteArray()
	var raw := var_to_bytes(fields)
	if raw.size() > Tuning.net.max_bulk_bytes:
		return PackedByteArray()
	var b := PackedByteArray()
	b.resize(BULK_HEADER)
	b.encode_u8(0, type)
	b.encode_u32(TYPE_BYTES, raw.size())
	b.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	if b.size() > Tuning.net.max_bulk_bytes:
		return PackedByteArray()
	return b


static func _decode_bulk_fields(b: PackedByteArray) -> Dictionary:
	if b.size() <= BULK_HEADER:
		return {}
	var raw_size := b.decode_u32(TYPE_BYTES)
	if raw_size < 1 or raw_size > Tuning.net.max_bulk_bytes:
		return {}
	var raw := b.slice(BULK_HEADER).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return {}
	return _bytes_to_dict(raw)


## Never decodes Objects; anything but a Dictionary is rejected.
static func _bytes_to_dict(b: PackedByteArray) -> Dictionary:
	# Cheap pre-check of the Variant header's type byte, so most garbage is
	# refused without the engine logging a decode error.
	if b.size() < SIZE_BYTES or (b.decode_u32(0) & U8_MAX) != TYPE_DICTIONARY:
		return {}
	var v: Variant = bytes_to_var(b)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	# A re-encode that differs in size means trailing garbage after the value.
	if var_to_bytes(v).size() != b.size():
		return {}
	return v


## Copy of the schema's fields with the right types, or {} if any is
## missing/mistyped/out of range.
static func _check_schema(type: int, fields: Dictionary) -> Dictionary:
	var schema: Dictionary = _SCHEMAS.get(type, {})
	if schema.is_empty():
		return {}
	var out := {}
	for key: String in schema:
		if not fields.has(key) or typeof(fields[key]) != schema[key]:
			return {}
		out[key] = fields[key]
	match type:
		Type.WELCOME:
			if not _peer_ok(out["peer_id"]) or not _peers_ok(out["peers"]):
				return {}
		Type.PEERS:
			if not _peers_ok(out["peers"]):
				return {}
		Type.CMD:
			var cmd: Dictionary = out["cmd"]
			if typeof(cmd.get("tick")) != TYPE_INT or typeof(cmd.get("kind")) != TYPE_INT \
					or not _tick_ok(cmd["tick"]):
				return {}
		Type.DROP:
			if not _peer_ok(out["peer"]) or not _tick_ok(out["last_tick"]):
				return {}
		Type.RESYNC, Type.SNAPSHOT:
			if not _tick_ok(out["tick"]):
				return {}
	return out


static func _peers_ok(peers: Dictionary) -> bool:
	for k: Variant in peers:
		if not _peer_ok(k) or typeof(peers[k]) != TYPE_STRING:
			return false
	return true
