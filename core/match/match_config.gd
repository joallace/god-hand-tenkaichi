class_name MatchConfig
extends Resource
## Everything needed to start a match. Menus build one and hand it to
## Game.start_match(). Adding a mode = new Mode value + how menus fill this in;
## MatchDirector and fighters don't change.

enum Mode { LOCAL_VERSUS, VERSUS_CPU, ONLINE }
enum Layout { SPLIT_SCREEN, SINGLE_VIEW }

@export var mode: Mode = Mode.LOCAL_VERSUS
@export var players: Array[PlayerSlotConfig] = []
@export var rounds_to_win: int = 2
## Seconds per round; 0 = infinite timer.
@export var round_time_seconds: int = 99
@export var arena_id: StringName = &"default"
## Seeds match randomness (CPU decisions). The join screen randomizes it;
## online peers would have to share it.
@export var rng_seed: int = 0


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


## Short on-screen name of a slot: "P1", "P2", or "CPU".
func player_tag(slot: int) -> String:
	for p in players:
		if p.slot == slot and p.input_kind == PlayerSlotConfig.InputKind.CPU:
			return "CPU"
	return "P%d" % (slot + 1)


## Slots whose camera should be rendered on this machine.
func local_view_slots() -> Array[int]:
	var out: Array[int] = []
	for p in players:
		if p.input_kind == PlayerSlotConfig.InputKind.LOCAL:
			out.append(p.slot)
	if out.is_empty() and not players.is_empty():
		out.append(players[0].slot)
	return out
