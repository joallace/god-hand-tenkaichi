class_name Replay
extends RefCounted
## A recorded match (SPEC_ONLINE.md §11): the config, every human slot's
## input frames, the sim command log and periodic state hashes. Enough to
## re-simulate the match exactly (CPU slots re-think with their own seeded
## brains) and to check that the re-simulation matches (ReplayPlayer).
##
## File (.ghr): MAGIC, u32 LE size of the payload, then the payload
## zstd-compressed. Payload = var_to_bytes(to_dict()), plain data only, read
## back with bytes_to_var (never with objects):
##   {format_version, engine_version (Engine version hex), game_build,
##    content_hash (ContentHash), config: MatchConfig.to_dict(),
##    inputs: {slot: PackedByteArray of InputFrame.WIRE_SIZE-byte frames,
##             frame for tick t at (t - 1) * WIRE_SIZE},
##    commands: [MatchDirector command dicts, log order], end_tick,
##    hashes: {tick: StateHash}}
## A replay from another engine / build / content still loads;
## version_mismatch() says why it may not play back identically.
##
## Storage: every match is kept as user://replays/last_<n>.ghr (n = 1 newest,
## rolling over Tuning.net.replay_keep_count, see save_auto); "Save replay"
## copies one to user://replays/saved/<date>_<mode>.ghr (save_copy).

const FORMAT_VERSION := 1
const MAGIC := "GHR1"
const HEADER_SIZE := 8
## Largest payload accepted when reading (decompression bomb guard).
const MAX_PAYLOAD_BYTES := 64 * 1024 * 1024
const EXT := ".ghr"
const AUTO_DIR := "user://replays/"
const AUTO_PREFIX := "last_"
const SAVED_DIR := "user://replays/saved/"

var format_version: int = FORMAT_VERSION
var engine_version: int = 0
var game_build: String = ""
var content_hash: String = ""
var config: Dictionary = {}
var inputs: Dictionary = {}  # slot -> PackedByteArray
var commands: Array[Dictionary] = []
var end_tick: int = 0
var hashes: Dictionary = {}  # tick -> int


## An empty replay of `cfg`, stamped with this build's versions.
static func create(cfg: MatchConfig) -> Replay:
	var r := Replay.new()
	r.engine_version = current_engine_version()
	r.game_build = current_game_build()
	r.content_hash = ContentHash.compute()
	r.config = cfg.to_dict()
	return r


static func current_engine_version() -> int:
	return Engine.get_version_info()["hex"]


## The version stamped at export (application/config/version), or "dev" in
## the editor / when none is set.
static func current_game_build() -> String:
	var v: Variant = ProjectSettings.get_setting("application/config/version", "")
	if OS.has_feature("editor") or not v is String or v == "":
		return "dev"
	return v


## The recorded config, or null if it doesn't validate.
func match_config() -> MatchConfig:
	return MatchConfig.from_dict(config)


## "" when this build matches the recording; otherwise why it may play back
## differently ("made with another version: ...").
func version_mismatch() -> String:
	var why: Array[String] = []
	if engine_version != current_engine_version():
		why.append("engine %x (this: %x)" % [engine_version, current_engine_version()])
	if game_build != current_game_build():
		why.append("build %s (this: %s)" % [game_build, current_game_build()])
	if content_hash != ContentHash.compute():
		why.append("game data differs")
	return "" if why.is_empty() else "made with another version: " + ", ".join(why)


# --- frames ---------------------------------------------------------------------

## Store `frame` as `slot`'s input for `tick` (overwrites: a re-simulated tick
## wins). Gaps are filled with neutral frames.
func set_frame(slot: int, tick: int, frame: InputFrame) -> void:
	var buf: PackedByteArray = inputs.get(slot, PackedByteArray())
	var w := InputFrame.WIRE_SIZE
	if buf.size() < tick * w:
		var neutral := InputFrame.new().to_bytes()
		while buf.size() < (tick - 1) * w:
			buf.append_array(neutral)
		buf.resize(tick * w)
	frame.encode_into(buf, (tick - 1) * w)
	inputs[slot] = buf


## `slot`'s frame for `tick` (neutral when not recorded).
func frame(slot: int, tick: int) -> InputFrame:
	return frame_from(inputs.get(slot, PackedByteArray()), tick)


static func frame_from(buf: PackedByteArray, tick: int) -> InputFrame:
	var off := (tick - 1) * InputFrame.WIRE_SIZE
	if tick < 1 or off + InputFrame.WIRE_SIZE > buf.size():
		return InputFrame.new()
	return InputFrame.decode_from(buf, off)


## Drop frames and hashes past end_tick.
func trim() -> void:
	for slot: int in inputs:
		var buf: PackedByteArray = inputs[slot]
		if buf.size() > end_tick * InputFrame.WIRE_SIZE:
			buf.resize(end_tick * InputFrame.WIRE_SIZE)
			inputs[slot] = buf
	for t: int in hashes.keys():
		if t > end_tick:
			hashes.erase(t)


# --- serialization ----------------------------------------------------------------

## Plain data, keys sorted where order could vary.
func to_dict() -> Dictionary:
	var ins := {}
	var slots := inputs.keys()
	slots.sort()
	for s: int in slots:
		ins[s] = inputs[s]
	var hs := {}
	var ticks := hashes.keys()
	ticks.sort()
	for t: int in ticks:
		hs[t] = hashes[t]
	var cmds: Array = []
	for c in commands:
		cmds.append(c.duplicate())
	return {
		"format_version": format_version, "engine_version": engine_version,
		"game_build": game_build, "content_hash": content_hash,
		"config": config.duplicate(true), "inputs": ins, "commands": cmds,
		"end_tick": end_tick, "hashes": hs,
	}


## Inverse of to_dict(); null when anything is malformed (wrong types, other
## format_version, a config or command that doesn't validate).
static func from_dict(d: Variant) -> Replay:
	if not d is Dictionary:
		return null
	var r := Replay.new()
	var fv: Variant = d.get("format_version")
	var ev: Variant = d.get("engine_version")
	var gb: Variant = d.get("game_build")
	var ch: Variant = d.get("content_hash")
	var cfg: Variant = d.get("config")
	var ins: Variant = d.get("inputs")
	var cmds: Variant = d.get("commands")
	var et: Variant = d.get("end_tick")
	var hs: Variant = d.get("hashes")
	if fv != FORMAT_VERSION or not ev is int or not gb is String or not ch is String or not cfg is Dictionary \
			or not ins is Dictionary or not cmds is Array or not et is int or et < 0 or not hs is Dictionary:
		return null
	if MatchConfig.from_dict(cfg) == null:
		return null
	for s: Variant in ins:
		var buf: Variant = ins[s]
		if not s is int or s < 0 or s > PlayerSlotConfig.MAX_SLOT or not buf is PackedByteArray \
				or (buf as PackedByteArray).size() % InputFrame.WIRE_SIZE != 0:
			return null
		r.inputs[s] = buf
	for c: Variant in cmds:
		var clean := MatchDirector.sanitize_command(c)
		if clean.is_empty():
			return null
		r.commands.append(clean)
	for t: Variant in hs:
		if not t is int or not hs[t] is int:
			return null
		r.hashes[t] = hs[t]
	r.engine_version = ev
	r.game_build = gb
	r.content_hash = ch
	r.config = cfg
	r.end_tick = et
	return r


func to_bytes() -> PackedByteArray:
	var payload := var_to_bytes(to_dict())
	var out := MAGIC.to_ascii_buffer()
	out.resize(HEADER_SIZE)
	out.encode_u32(MAGIC.length(), payload.size())
	out.append_array(payload.compress(FileAccess.COMPRESSION_ZSTD))
	return out


## Null when the bytes aren't a valid replay.
static func from_bytes(b: PackedByteArray) -> Replay:
	if b.size() < HEADER_SIZE or b.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return null
	var size := b.decode_u32(MAGIC.length())
	if size <= 0 or size > MAX_PAYLOAD_BYTES:
		return null
	var payload := b.slice(HEADER_SIZE).decompress(size, FileAccess.COMPRESSION_ZSTD)
	if payload.size() != size:
		return null
	return from_dict(bytes_to_var(payload))


func save(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(to_bytes())
	f.close()
	return OK


## Null when the file is missing or invalid.
static func load_file(path: String) -> Replay:
	if not FileAccess.file_exists(path):
		return null
	return from_bytes(FileAccess.get_file_as_bytes(path))


# --- storage ------------------------------------------------------------------------

## Write as the newest auto-kept replay (dir/last_1.ghr), shifting older ones
## up and dropping the one past Tuning.net.replay_keep_count. Returns the
## path, or "" when keeping is off (count 0) or the write failed.
func save_auto(dir: String = AUTO_DIR) -> String:
	var keep := Tuning.net.replay_keep_count
	if keep <= 0:
		return ""
	DirAccess.make_dir_recursive_absolute(dir)
	var oldest := auto_path(keep, dir)
	if FileAccess.file_exists(oldest):
		DirAccess.remove_absolute(oldest)
	for n in range(keep - 1, 0, -1):
		if FileAccess.file_exists(auto_path(n, dir)):
			DirAccess.rename_absolute(auto_path(n, dir), auto_path(n + 1, dir))
	var path := auto_path(1, dir)
	return path if save(path) == OK else ""


static func auto_path(n: int, dir: String = AUTO_DIR) -> String:
	return dir.path_join("%s%d%s" % [AUTO_PREFIX, n, EXT])


## "Save replay": write a copy to dir/<dest_name>.ghr (default name
## <date>_<mode>). Returns the path, or "" on failure.
func save_copy(dest_name: String = "", dir: String = SAVED_DIR) -> String:
	if dest_name == "":
		dest_name = default_saved_name()
	var path := dir.path_join(dest_name.validate_filename() + EXT)
	return path if save(path) == OK else ""


## <YYYY-MM-DD_HH-MM-SS>_<mode>, e.g. 2026-10-19_21-04-55_coop.
func default_saved_name() -> String:
	var date := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	var mode_v: Variant = config.get("mode", 0)
	var mode_name: String = str(MatchConfig.Mode.find_key(mode_v)).to_lower() if mode_v is int else "match"
	return "%s_%s" % [date, mode_name]
