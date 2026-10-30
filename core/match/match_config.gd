class_name MatchConfig
extends Resource
## Everything needed to start a match. Menus build one and hand it to
## Game.start_match(). Adding a mode = new Mode value + how menus fill this in;
## MatchDirector and fighters don't change.

enum Mode { LOCAL_VERSUS, VERSUS_CPU, ONLINE, COOP }
enum Layout { SPLIT_SCREEN, SINGLE_VIEW }

## from_dict() limits (structural sanity caps for untrusted data, not rules).
const MAX_PLAYERS := 16
const MAX_ROUNDS_TO_WIN := 99
const MAX_ROUND_SECONDS := 999
const MAX_ID_LENGTH := 64
const MAX_FIELD_CAP := 16
const MAX_ROLLBACK_FRAMES := 30

@export var mode: Mode = Mode.LOCAL_VERSUS
@export var players: Array[PlayerSlotConfig] = []
@export var rounds_to_win: int = 2
## Seconds per round; 0 = infinite timer.
@export var round_time_seconds: int = 99
@export var arena_id: StringName = &"default"
## Seeds match randomness (CPU decisions). The join screen randomizes it;
## online peers would have to share it.
@export var rng_seed: int = 0
## Whether hitboxes hurt fighters of the attacker's own team.
@export var friendly_fire: bool = false
## Co-op run setup (Mode.COOP only, else null).
@export var coop: CoopConfig
## Online caps the host picks for the session (apply_platform_caps), shared
## in MATCH_START so every peer simulates the same field. 0 = the Tuning
## default (coop.online_field_cap, net.max_rollback_frames).
@export var online_field_cap: int = 0
@export var max_rollback_frames: int = 0


static func from_defaults(p_mode: Mode = Mode.LOCAL_VERSUS) -> MatchConfig:
	var c := MatchConfig.new()
	c.mode = p_mode
	c.rounds_to_win = Tuning.match_rules.rounds_to_win
	c.round_time_seconds = Tuning.match_rules.round_time_seconds
	return c


func is_infinite_time() -> bool:
	return round_time_seconds <= 0


## Split screen when 2+ local humans share the machine; one view otherwise.
func layout() -> Layout:
	var locals := 0
	for p in players:
		if p.input_kind == PlayerSlotConfig.InputKind.LOCAL:
			locals += 1
	return Layout.SPLIT_SCREEN if locals >= 2 else Layout.SINGLE_VIEW


## Short on-screen name of a slot: "CPU" for CPU slots; for humans the
## profile `display_name` when online (is_online()) and set, else "P1", "P2"...
func player_tag(slot: int) -> String:
	for p in players:
		if p.slot != slot:
			continue
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			return "CPU"
		if p.display_name != "" and is_online():
			return p.display_name
	return "P%d" % (slot + 1)


## Online match: Mode.ONLINE, or any slot owned by a peer (owner_peer != 0;
## offline configs leave every owner_peer at 0).
func is_online() -> bool:
	if mode == Mode.ONLINE:
		return true
	for p in players:
		if p.owner_peer != 0:
			return true
	return false


## Derive each slot's input_kind as seen from peer `me` (SPEC_ONLINE.md §4),
## in place: CPU stays CPU, slots owned by `me` become LOCAL (their
## device_kind / device_id only mean anything on the owner), every other
## slot NETWORK. Call it on the shared config (e.g. a from_dict() copy) once
## per machine. Returns self.
func localize_for_peer(me: int) -> MatchConfig:
	for p in players:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			continue
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL if p.owner_peer == me else PlayerSlotConfig.InputKind.NETWORK
	return self


## Bindings profile (Bindings.profile_for) of LOCAL `slot` among the LOCAL
## players (owned by peer `me` when >= 0), in slot order; 0 if not one.
func binding_profile(slot: int, me: int = -1) -> int:
	var kinds: Array = []
	var at := -1
	for p in players:
		if p.input_kind != PlayerSlotConfig.InputKind.LOCAL or (me >= 0 and p.owner_peer != me):
			continue
		if p.slot == slot:
			at = kinds.size()
		kinds.append(p.device_kind)
	return Bindings.profile_for(kinds, at) if at >= 0 else 0


## Slots whose camera should be rendered on this machine.
func local_view_slots() -> Array[int]:
	var out: Array[int] = []
	for p in players:
		if p.input_kind == PlayerSlotConfig.InputKind.LOCAL:
			out.append(p.slot)
	if out.is_empty() and not players.is_empty():
		out.append(players[0].slot)
	return out


## Host, online: the caps for a session with a browser peer
## (Tuning.coop.online_field_cap_web, Tuning.net.max_rollback_frames_web;
## the browser re-simulates ~1.6x slower, docs/SPEC_online.md §12.1) or the
## defaults (0) without one. Config, not code branches: every peer reads the
## same values from MATCH_START. Returns self.
func apply_platform_caps(has_web_peer: bool) -> MatchConfig:
	online_field_cap = Tuning.coop.online_field_cap_web if has_web_peer else 0
	max_rollback_frames = Tuning.net.max_rollback_frames_web if has_web_peer else 0
	return self


## max_rollback_frames, or Tuning.net.max_rollback_frames when unset.
func rollback_frames() -> int:
	return max_rollback_frames if max_rollback_frames > 0 else Tuning.net.max_rollback_frames


# --- plain-data form (wire, replays) -------------------------------------------

## Plain Dictionary/Array/int/bool/String copy (no Resources), so it can go
## through var_to_bytes / bytes_to_var (never with objects). from_dict(to_dict())
## rebuilds an equal config.
func to_dict() -> Dictionary:
	var ps: Array = []
	for p in players:
		ps.append(p.to_dict())
	return {
		"mode": mode, "players": ps, "rounds_to_win": rounds_to_win,
		"round_time_seconds": round_time_seconds, "arena_id": String(arena_id),
		"rng_seed": rng_seed, "friendly_fire": friendly_fire,
		"coop": coop.to_dict() if coop != null else null,
		"online_field_cap": online_field_cap, "max_rollback_frames": max_rollback_frames,
	}


## Inverse of to_dict(). Fed network / file data, so it never trusts it:
## wrong types, an unknown mode or character, too many players, duplicate
## slots or a COOP config without its coop block return null; numbers are
## clamped to sane ranges (MAX_ROUNDS_TO_WIN, MAX_ROUND_SECONDS).
static func from_dict(d: Variant) -> MatchConfig:
	if not d is Dictionary:
		return null
	var c := MatchConfig.new()
	var mode_v: Variant = dict_int(d, "mode", Mode.LOCAL_VERSUS, 0, Mode.size() - 1, false)
	var rounds_v: Variant = dict_int(d, "rounds_to_win", c.rounds_to_win, 1, MAX_ROUNDS_TO_WIN)
	var time_v: Variant = dict_int(d, "round_time_seconds", c.round_time_seconds, 0, MAX_ROUND_SECONDS)
	var seed_v: Variant = d.get("rng_seed", 0)
	var arena_v: Variant = d.get("arena_id", String(c.arena_id))
	var ff_v: Variant = d.get("friendly_fire", false)
	var ps: Variant = d.get("players", [])
	var coop_v: Variant = d.get("coop", null)
	var cap_v: Variant = dict_int(d, "online_field_cap", 0, 0, MAX_FIELD_CAP)
	var rb_v: Variant = dict_int(d, "max_rollback_frames", 0, 0, MAX_ROLLBACK_FRAMES)
	if mode_v == null or rounds_v == null or time_v == null or cap_v == null or rb_v == null \
			or not seed_v is int or not ff_v is bool \
			or not (arena_v is String or arena_v is StringName) or String(arena_v).length() > MAX_ID_LENGTH \
			or not ps is Array or (ps as Array).size() > MAX_PLAYERS:
		return null
	var seen := {}
	for pd: Variant in ps:
		var p := PlayerSlotConfig.from_dict(pd)
		if p == null or seen.has(p.slot):
			return null
		seen[p.slot] = true
		c.players.append(p)
	if coop_v != null:
		c.coop = CoopConfig.from_dict(coop_v)
		if c.coop == null:
			return null
	c.mode = mode_v
	if c.mode == Mode.COOP and c.coop == null:
		return null
	c.rounds_to_win = rounds_v
	c.round_time_seconds = time_v
	c.rng_seed = seed_v
	c.arena_id = StringName(arena_v)
	c.friendly_fire = ff_v
	c.online_field_cap = cap_v
	c.max_rollback_frames = rb_v
	return c


## d[key] as an int in [lo, hi]: `default` when missing, null when not an
## int, clamped when out of range (null instead when clamp_value is false).
static func dict_int(d: Dictionary, key: String, default: int, lo: int, hi: int, clamp_value: bool = true) -> Variant:
	if not d.has(key):
		return default
	var v: Variant = d[key]
	if not v is int:
		return null
	if v < lo or v > hi:
		return clampi(v, lo, hi) if clamp_value else null
	return v


## d[key] as a character id: &"" when missing or empty (= random / default),
## null when not a string or not a registered character.
static func dict_character(d: Dictionary, key: String) -> Variant:
	var v: Variant = d.get(key, "")
	if not (v is String or v is StringName):
		return null
	if String(v) == "":
		return &""
	return StringName(v) if StringName(v) in CharacterRegistry.ids() else null
