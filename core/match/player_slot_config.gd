class_name PlayerSlotConfig
extends Resource
## Who controls a fighter and with what. Built by the join screen (or, online,
## decoded from the host's lobby state with from_dict()).

enum InputKind { LOCAL, CPU, NETWORK }

## Highest slot / team / device id from_dict() accepts.
const MAX_SLOT := 63

@export var slot: int = 0
## Team id; fighters on the same team are allies. -1 = own team (= slot), so
## a plain 1v1 config is two teams of one.
@export var team: int = -1
@export var character_id: StringName = &"brawler"
@export var input_kind: InputKind = InputKind.LOCAL
## For LOCAL: Bindings.Kind (PAD or KEYBOARD).
@export var device_kind: int = 0
## For LOCAL pads: the joypad device id.
@export var device_id: int = -1
## For CPU: difficulty level, an index into Tuning.cpu.level_names
## (-1 = Tuning.cpu.default_level).
@export var cpu_level: int = -1
## Peer (machine) that owns this slot online; 0 = local / offline. Each peer
## derives input_kind from it (MatchConfig.localize_for_peer).
@export var owner_peer: int = 0
## Profile name of a human online ("" offline). See MatchConfig.player_tag.
@export var display_name: String = ""


## LOCAL slots read Bindings `profile` (MatchConfig.binding_profile; -1 =
## the slot number, fine for the first two slots only).
func create_input_source(profile: int = -1) -> InputSource:
	match input_kind:
		InputKind.CPU:
			return CpuInput.new(cpu_level)
		InputKind.NETWORK:
			return NetworkInput.new()
	return LocalDeviceInput.new(profile if profile >= 0 else slot, device_kind, device_id)


## Plain-data copy (int/String only) for the wire and replay files.
func to_dict() -> Dictionary:
	return {
		"slot": slot, "team": team, "character_id": String(character_id),
		"input_kind": input_kind, "device_kind": device_kind, "device_id": device_id,
		"cpu_level": cpu_level, "owner_peer": owner_peer, "display_name": display_name,
	}


## Inverse of to_dict(). Fed network data: wrong types, an unknown character,
## input kind or slot return null; other numbers are clamped and the name is
## sanitized (sanitize_name). Missing keys take the defaults.
static func from_dict(d: Variant) -> PlayerSlotConfig:
	if not d is Dictionary:
		return null
	var p := PlayerSlotConfig.new()
	var slot_v: Variant = MatchConfig.dict_int(d, "slot", 0, 0, MAX_SLOT, false)
	var team_v: Variant = MatchConfig.dict_int(d, "team", -1, -1, MAX_SLOT)
	var kind_v: Variant = MatchConfig.dict_int(d, "input_kind", InputKind.LOCAL, 0, InputKind.size() - 1, false)
	var dev_kind_v: Variant = MatchConfig.dict_int(d, "device_kind", 0, 0, Bindings.Kind.size() - 1)
	var dev_id_v: Variant = MatchConfig.dict_int(d, "device_id", -1, -1, MAX_SLOT)
	var lvl_v: Variant = MatchConfig.dict_int(d, "cpu_level", -1, -1, Tuning.cpu.level_count() - 1)
	var peer_v: Variant = MatchConfig.dict_int(d, "owner_peer", 0, 0, 0x7FFFFFFF)
	var ch: Variant = d.get("character_id", String(p.character_id))
	var nm: Variant = d.get("display_name", "")
	if slot_v == null or team_v == null or kind_v == null or dev_kind_v == null or dev_id_v == null \
			or lvl_v == null or peer_v == null or not (ch is String or ch is StringName) or not nm is String:
		return null
	if not StringName(ch) in CharacterRegistry.ids():
		return null
	p.slot = slot_v
	p.team = team_v
	p.input_kind = kind_v
	p.device_kind = dev_kind_v
	p.device_id = dev_id_v
	p.cpu_level = lvl_v
	p.owner_peer = peer_v
	p.character_id = StringName(ch)
	p.display_name = sanitize_name(nm)
	return p


## Printable characters only, trimmed to Tuning.net.name_max_len.
static func sanitize_name(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x20 and c != 0x7F:
			out += char(c)
	return out.strip_edges().left(Tuning.net.name_max_len)
