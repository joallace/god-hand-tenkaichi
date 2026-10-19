class_name LobbyModel
extends RefCounted
## The lobby's data and rules (SPEC_ONLINE.md §10.2), without UI or input
## devices: slots, the per-player rows, the shared match / co-op rules, the
## start condition, and the MatchConfig they build. The Lobby screen drives
## one directly offline; online the host's OnlineRoom owns the real one and
## guests mirror it from `to_dict()` (apply_dict), sending their commands to
## the host instead of applying them.
##
## Modes: `mode` picks the slot layout (configure_for_mode):
##   LOCAL_VERSUS [HUMAN, HUMAN]; VERSUS_CPU [HUMAN, CPU] (the CPU slot is
##   pre-joined and ready; humans get "CPU fighter" / "CPU level" rows);
##   COOP [HUMAN, HUMAN], both optional (SPEC.md §9 rows); ONLINE (versus over
##   the network) [HUMAN, HUMAN] where each slot records the peer that owns it.
## The MODE row switches between `modes()` (offline: the three local modes;
## online: ONLINE and COOP).
##
## Online: a slot's `owner_peer` is the peer that joined it (0 = free).
## Shared rows (rules) belong to the host: a guest's slot only has the
## CHARACTER row, and a rule change by the host un-readies everyone else.
## Online co-op (SPEC_ONLINE.md §15 milestone 3) has
## min(Tuning.net.max_humans, max_fighters) optional HUMAN slots; the CPU
## ally takes one of the Tuning.net.max_fighters places (human_capacity), so
## it can't be switched on with every place taken. Switching modes online
## packs the joined humans into the new layout's human slots in slot order
## (a peer whose slot no longer exists is left without one).

enum SlotType { HUMAN, CPU }
enum SlotState { EMPTY, JOINED, READY }
enum Cmd { UP, DOWN, LEFT, RIGHT, CONFIRM, BACK }
enum Row {
	CHARACTER, CPU_CHARACTER, CPU_LEVEL, ROUNDS, TIMER,
	COOP_STRUCTURE, ENEMY_COUNT, WAVES, ENEMY_LEVEL, ENEMY_ROSTER,
	ALLY, ALLY_LEVEL, ALLY_CHARACTER, FRIENDLY_FIRE, MODE,
}

## What a command did (the screen plays sounds / punches panels for it).
const EV_NONE := &""
const EV_MOVE := &"move"
const EV_READY := &"ready"
const EV_UNREADY := &"unready"
const EV_LEAVE := &"leave"
const EV_JOIN := &"join"

## Offline modes, in MODE row order.
const LOCAL_MODES: Array[MatchConfig.Mode] = [
	MatchConfig.Mode.LOCAL_VERSUS, MatchConfig.Mode.VERSUS_CPU, MatchConfig.Mode.COOP]
const ONLINE_MODES: Array[MatchConfig.Mode] = [MatchConfig.Mode.ONLINE, MatchConfig.Mode.COOP]
const MIN_ROUNDS := 1
const MAX_ROUNDS := 5

## Settings/characters remembered across visits (offline; Change Setup).
static var _memory: Dictionary = {}
## Co-op run setup remembered across visits (separate from versus).
static var _coop_memory: Dictionary = {}

class Slot:
	var type: int = SlotType.HUMAN
	var state: int = SlotState.EMPTY
	var device_kind: int = Bindings.Kind.PAD
	var device_id: int = -1
	var char_index: int = 0
	var cursor: int = Row.CHARACTER
	## Online: the peer that joined this slot (0 = free / offline).
	var owner_peer: int = 0
	var display_name: String = ""
	var join_order: int = 0
	## CPU slots: difficulty, an index into Tuning.cpu.level_names.
	var cpu_level: int = Tuning.cpu.clamp_level(-1)

var mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS
## Networked lobby (ONLINE modes, owner peers, host-only rules).
var online := false
var slots: Array[Slot] = []
var rounds_to_win: int = 2
var time_index: int = 0
var time_options: PackedInt32Array

# Co-op run setup (COOP mode only).
var coop_structure: int = Tuning.coop.default_structure
var coop_enemy_count: int = Tuning.coop.default_enemy_count
## 1..max_wave_count, or max_wave_count + 1 = endless.
var coop_waves: int = Tuning.coop.default_wave_count
var coop_enemy_level: int = Tuning.cpu.clamp_level(-1)
## 0 = random, else 1 + index into MenuHelpers.character_ids().
var coop_roster: int = 0
var coop_ally: bool = false
var coop_ally_level: int = Tuning.cpu.clamp_level(-1)
var coop_ally_char: int = 0
var friendly_fire: bool = false

var _join_counter := 0


func _init(p_mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS, p_online := false) -> void:
	var rules: MatchTuning = Tuning.match_rules
	time_options = rules.round_time_options
	if time_options.is_empty():
		time_options = PackedInt32Array([rules.round_time_seconds])
	rounds_to_win = clampi(rules.rounds_to_win, MIN_ROUNDS, MAX_ROUNDS)
	time_index = maxi(time_options.find(rules.round_time_seconds), 0)
	online = p_online
	set_mode(p_mode)


## Switch mode: rebuild the slot layout, keeping joined humans (and their
## picks) where the new layout still has a human slot.
func set_mode(m: MatchConfig.Mode) -> void:
	var old := slots.duplicate()
	mode = m
	configure_for_mode()
	if online:
		_pack_humans(old)
	else:
		for i in mini(old.size(), slots.size()):
			if old[i].type == SlotType.HUMAN and slots[i].type == SlotType.HUMAN:
				slots[i] = old[i]
				if slots[i].state == SlotState.READY:
					slots[i].state = SlotState.JOINED
			elif slots[i].type == SlotType.HUMAN or old[i].type == SlotType.HUMAN:
				slots[i].char_index = old[i].char_index
	if is_coop() and time_options.find(0) >= 0:
		time_index = time_options.find(0)  # co-op runs default to no time limit
	fix_cursors()


## Slot layout per mode.
func configure_for_mode() -> void:
	var types: Array[int]
	match mode:
		MatchConfig.Mode.VERSUS_CPU:
			types = [SlotType.HUMAN, SlotType.CPU]
		_:
			types = [SlotType.HUMAN, SlotType.HUMAN]
	if online and is_coop():
		types = []
		for i in mini(Tuning.net.max_humans, Tuning.net.max_fighters):
			types.append(SlotType.HUMAN)
	slots.clear()
	for t in types:
		var s := Slot.new()
		s.type = t
		if t == SlotType.CPU:
			s.state = SlotState.READY
		slots.append(s)


## Online: joined humans keep their picks in the new layout's human slots,
## in slot order, un-readied; picks of empty slots carry over by index.
func _pack_humans(old: Array) -> void:
	var joined: Array = old.filter(func(s: Slot) -> bool:
		return s.type == SlotType.HUMAN and s.state != SlotState.EMPTY)
	for i in slots.size():
		if i < old.size():
			slots[i].char_index = old[i].char_index
		if slots[i].type != SlotType.HUMAN or joined.is_empty():
			continue
		slots[i] = joined.pop_front()
		if slots[i].state == SlotState.READY:
			slots[i].state = SlotState.JOINED


func modes() -> Array[MatchConfig.Mode]:
	return ONLINE_MODES if online else LOCAL_MODES


static func mode_name(m: MatchConfig.Mode) -> String:
	match m:
		MatchConfig.Mode.VERSUS_CPU:
			return "Versus CPU"
		MatchConfig.Mode.COOP:
			return "Co-op"
	return "Versus"


func is_coop() -> bool:
	return mode == MatchConfig.Mode.COOP


func coop_endless() -> bool:
	return coop_waves > Tuning.coop.max_wave_count


# --- slots ---------------------------------------------------------------------

func first_free_slot() -> int:
	if joined_humans() >= human_capacity():
		return -1
	for i in slots.size():
		if slots[i].type == SlotType.HUMAN and slots[i].state == SlotState.EMPTY:
			return i
	return -1


func joined_humans() -> int:
	var n := 0
	for s in slots:
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY:
			n += 1
	return n


## Humans that can join: every HUMAN slot, minus the CPU ally's place
## online (Tuning.net.max_fighters fighters in all).
func human_capacity() -> int:
	var n := 0
	for s in slots:
		if s.type == SlotType.HUMAN:
			n += 1
	if online and is_coop() and coop_ally:
		n = mini(n, Tuning.net.max_fighters - 1)
	return n


func nobody_joined() -> bool:
	for s in slots:
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY:
			return false
	return true


func cpu_slot() -> int:
	for i in slots.size():
		if slots[i].type == SlotType.CPU:
			return i
	return -1


## Joined human slots owned by `peer`, in slot order.
func slots_of(peer: int) -> Array[int]:
	var out: Array[int] = []
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY and s.owner_peer == peer:
			out.append(i)
	return out


## Claim the next free HUMAN slot. Returns the slot or -1.
func join(kind: int, device: int, owner: int = 0, player_name: String = "") -> int:
	var idx := first_free_slot()
	if idx < 0:
		return -1
	var s := slots[idx]
	s.state = SlotState.JOINED
	s.device_kind = kind
	s.device_id = device if kind == Bindings.Kind.PAD else -1
	s.cursor = Row.CHARACTER
	s.owner_peer = owner
	s.display_name = player_name
	_join_counter += 1
	s.join_order = _join_counter
	return idx


func leave(idx: int) -> void:
	if idx < 0 or idx >= slots.size() or slots[idx].type != SlotType.HUMAN:
		return
	var s := slots[idx]
	s.state = SlotState.EMPTY
	s.device_id = -1
	s.owner_peer = 0
	s.display_name = ""


## Every slot owned by `peer` freed (a guest left the room).
func remove_peer(peer: int) -> void:
	for i in slots_of(peer):
		leave(i)


## Every ready human back to JOINED (online: a rule change, back to lobby).
func unready_all(except: int = -1) -> void:
	for i in slots.size():
		var s := slots[i]
		if i != except and s.type == SlotType.HUMAN and s.state == SlotState.READY:
			s.state = SlotState.JOINED


## Apply a player's menu command to slot `idx`. Returns what happened (EV_*).
func command(idx: int, cmd: int) -> StringName:
	if idx < 0 or idx >= slots.size():
		return EV_NONE
	var s := slots[idx]
	match s.state:
		SlotState.READY:
			if cmd == Cmd.BACK:
				s.state = SlotState.JOINED
				return EV_UNREADY
		SlotState.JOINED:
			match cmd:
				Cmd.UP:
					_move_cursor(idx, -1)
					return EV_MOVE
				Cmd.DOWN:
					_move_cursor(idx, 1)
					return EV_MOVE
				Cmd.LEFT:
					_change_row(idx, -1)
					return EV_MOVE
				Cmd.RIGHT:
					_change_row(idx, 1)
					return EV_MOVE
				Cmd.CONFIRM:
					s.state = SlotState.READY
					return EV_READY
				Cmd.BACK:
					leave(idx)
					return EV_LEAVE
	return EV_NONE


## Rows the player in slot `idx` can pick, top to bottom (online guests:
## their character only; the rules are the host's).
func rows_for(idx: int) -> Array[int]:
	if online and idx >= 0 and idx < slots.size() and slots[idx].owner_peer != Transport.HOST_PEER:
		return [Row.CHARACTER]
	return rows()


## Every row this mode shows, top to bottom.
func rows() -> Array[int]:
	var r: Array[int] = [Row.CHARACTER]
	if modes().size() > 1:
		r.append(Row.MODE)
	if is_coop():
		r.append_array([Row.COOP_STRUCTURE, Row.ENEMY_COUNT])
		if coop_structure == CoopConfig.Structure.WAVES:
			r.append(Row.WAVES)
		r.append_array([Row.ENEMY_LEVEL, Row.ENEMY_ROSTER, Row.ALLY])
		if coop_ally:
			r.append_array([Row.ALLY_LEVEL, Row.ALLY_CHARACTER])
		r.append_array([Row.FRIENDLY_FIRE, Row.TIMER])
		return r
	if cpu_slot() >= 0:
		r.append_array([Row.CPU_CHARACTER, Row.CPU_LEVEL])
	r.append_array([Row.ROUNDS, Row.TIMER])
	return r


func _move_cursor(idx: int, dir: int) -> void:
	var r := rows_for(idx)
	var s := slots[idx]
	s.cursor = r[posmod(maxi(r.find(s.cursor), 0) + dir, r.size())]


func _change_row(idx: int, dir: int) -> void:
	var s := slots[idx]
	if not s.cursor in rows_for(idx):
		s.cursor = Row.CHARACTER
	var n := MenuHelpers.character_ids().size()
	match s.cursor:
		Row.CHARACTER:
			s.char_index = posmod(s.char_index + dir, maxi(n, 1))
			return
		Row.MODE:
			var ms := modes()
			set_mode(ms[posmod(maxi(ms.find(mode), 0) + dir, ms.size())])
		Row.CPU_CHARACTER:
			var cpu := slots[cpu_slot()]
			cpu.char_index = posmod(cpu.char_index + dir, maxi(n, 1))
		Row.CPU_LEVEL:
			var cpu := slots[cpu_slot()]
			cpu.cpu_level = clampi(cpu.cpu_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ROUNDS:
			rounds_to_win = clampi(rounds_to_win + dir, MIN_ROUNDS, MAX_ROUNDS)
		Row.TIMER:
			time_index = posmod(time_index + dir, time_options.size())
		Row.COOP_STRUCTURE:
			coop_structure = posmod(coop_structure + dir, CoopConfig.Structure.size())
		Row.ENEMY_COUNT:
			coop_enemy_count = clampi(coop_enemy_count + dir, 1, Tuning.coop.max_enemy_count)
		Row.WAVES:
			coop_waves = posmod(coop_waves - 1 + dir, Tuning.coop.max_wave_count + 1) + 1
		Row.ENEMY_LEVEL:
			coop_enemy_level = clampi(coop_enemy_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ENEMY_ROSTER:
			coop_roster = posmod(coop_roster + dir, n + 1)
		Row.ALLY:
			if not coop_ally and online and joined_humans() >= Tuning.net.max_fighters:
				return  # no place left for the ally
			coop_ally = not coop_ally
		Row.ALLY_LEVEL:
			coop_ally_level = clampi(coop_ally_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ALLY_CHARACTER:
			coop_ally_char = posmod(coop_ally_char + dir, maxi(n, 1))
		Row.FRIENDLY_FIRE:
			friendly_fire = not friendly_fire
	# A shared rule changed: online, everyone has to confirm it again.
	if online:
		unready_all(idx)
	fix_cursors()


## Rows hidden by a change (Waves in Brawl, ally rows without an ally, CPU
## rows after a mode switch) send any cursor on them back to the row that
## controls them.
func fix_cursors() -> void:
	for i in slots.size():
		var s := slots[i]
		var r := rows_for(i)
		if s.cursor in r:
			continue
		match s.cursor:
			Row.WAVES:
				s.cursor = Row.COOP_STRUCTURE
			Row.ALLY_LEVEL, Row.ALLY_CHARACTER:
				s.cursor = Row.ALLY
			_:
				s.cursor = Row.MODE if Row.MODE in r else Row.CHARACTER


## The match can start: co-op needs one joined human with every joined one
## ready; versus needs every slot ready.
func all_ready() -> bool:
	if is_coop():
		return not nobody_joined() and slots.all(func(s: Slot) -> bool: return s.state != SlotState.JOINED)
	for s in slots:
		if s.state != SlotState.READY:
			return false
	return not slots.is_empty()


# --- config ----------------------------------------------------------------------

## The MatchConfig these settings describe (rng_seed = `seed_value`).
## Online slots carry owner_peer / display_name and input kind LOCAL (each
## peer localizes it, MatchConfig.localize_for_peer).
func build_config(seed_value: int) -> MatchConfig:
	if is_coop():
		return build_coop_config(seed_value)
	var cfg := MatchConfig.from_defaults(mode)
	cfg.rounds_to_win = rounds_to_win
	cfg.round_time_seconds = time_options[time_index]
	cfg.rng_seed = seed_value
	var ids := MenuHelpers.character_ids()
	for i in slots.size():
		var s := slots[i]
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = ids[s.char_index] if s.char_index < ids.size() else ids[0]
		match s.type:
			SlotType.CPU:
				p.input_kind = PlayerSlotConfig.InputKind.CPU
				p.cpu_level = s.cpu_level
			_:
				p.input_kind = PlayerSlotConfig.InputKind.LOCAL
				p.device_kind = s.device_kind
				p.device_id = s.device_id
				p.owner_peer = s.owner_peer
				p.display_name = s.display_name
		cfg.players.append(p)
	return cfg


## COOP: joined humans (in slot order, renumbered from 0) and the optional
## CPU ally on team 0; the run itself in cfg.coop.
func build_coop_config(seed_value: int) -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = time_options[time_index]
	cfg.rng_seed = seed_value
	cfg.friendly_fire = friendly_fire
	var ids := MenuHelpers.character_ids()
	for s in slots:
		if s.type != SlotType.HUMAN or s.state == SlotState.EMPTY:
			continue
		var p := PlayerSlotConfig.new()
		p.slot = cfg.players.size()
		p.team = 0
		p.character_id = ids[clampi(s.char_index, 0, ids.size() - 1)]
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL
		p.device_kind = s.device_kind
		p.device_id = s.device_id
		p.owner_peer = s.owner_peer
		p.display_name = s.display_name
		cfg.players.append(p)
	var c := CoopConfig.new()
	c.structure = coop_structure
	c.enemy_count = coop_enemy_count
	c.endless = coop_structure == CoopConfig.Structure.WAVES and coop_endless()
	if coop_structure == CoopConfig.Structure.WAVES and not c.endless:
		for i in coop_waves:
			c.waves.append(WaveConfig.new())  # count 0 = c.enemy_count
	c.enemy_level = coop_enemy_level
	c.enemy_character = ids[coop_roster - 1] if coop_roster > 0 and coop_roster <= ids.size() else &""
	c.ally_enabled = coop_ally
	c.ally_level = coop_ally_level
	c.ally_character = ids[clampi(coop_ally_char, 0, ids.size() - 1)]
	if coop_ally:
		var a := PlayerSlotConfig.new()
		a.slot = cfg.players.size()
		a.team = 0
		a.character_id = c.ally_character
		a.input_kind = PlayerSlotConfig.InputKind.CPU
		a.cpu_level = coop_ally_level
		cfg.players.append(a)
	cfg.coop = c
	return cfg


## A new room takes a local lobby's rules: co-op stays co-op (with its run
## setup), any versus becomes online versus.
func carry_rules_from(local: LobbyModel) -> void:
	rounds_to_win = local.rounds_to_win
	coop_structure = local.coop_structure
	coop_enemy_count = local.coop_enemy_count
	coop_waves = local.coop_waves
	coop_enemy_level = local.coop_enemy_level
	coop_roster = local.coop_roster
	coop_ally = local.coop_ally
	coop_ally_level = local.coop_ally_level
	coop_ally_char = local.coop_ally_char
	friendly_fire = local.friendly_fire
	set_mode(MatchConfig.Mode.COOP if local.is_coop() and MatchConfig.Mode.COOP in modes() else MatchConfig.Mode.ONLINE)
	time_index = local.time_index


# --- wire form (host -> guests) ---------------------------------------------------

## Plain data for LOBBY_STATE (no device ids: they only mean something on
## the machine that owns the slot).
func to_dict() -> Dictionary:
	var ss: Array = []
	for s in slots:
		ss.append({"type": s.type, "state": s.state, "char": s.char_index, "cursor": s.cursor,
			"owner": s.owner_peer, "name": s.display_name, "order": s.join_order, "cpu_level": s.cpu_level})
	return {
		"mode": mode, "online": online, "slots": ss, "rounds": rounds_to_win, "time": time_index,
		"coop": [coop_structure, coop_enemy_count, coop_waves, coop_enemy_level, coop_roster,
			coop_ally, coop_ally_level, coop_ally_char],
		"ff": friendly_fire,
	}


## Mirror the host's to_dict(). Untrusted network data: wrong types are
## skipped, numbers clamped. Returns false if it isn't a lobby at all.
func apply_dict(d: Dictionary) -> bool:
	var ss: Variant = d.get("slots")
	var m: Variant = d.get("mode")
	if not ss is Array or not m is int or m < 0 or m >= MatchConfig.Mode.size() \
			or (ss as Array).size() > Tuning.net.max_fighters:
		return false
	mode = m
	online = d.get("online", online) == true
	var n := maxi(MenuHelpers.character_ids().size(), 1)
	slots.clear()
	for sd: Variant in ss:
		var s := Slot.new()
		if sd is Dictionary:
			s.type = clampi(_int(sd, "type", s.type), 0, SlotType.size() - 1)
			s.state = clampi(_int(sd, "state", s.state), 0, SlotState.size() - 1)
			s.char_index = clampi(_int(sd, "char", 0), 0, n - 1)
			s.cursor = clampi(_int(sd, "cursor", Row.CHARACTER), 0, Row.size() - 1)
			s.owner_peer = clampi(_int(sd, "owner", 0), 0, Transport.MAX_PEER_ID)
			s.display_name = PlayerSlotConfig.sanitize_name(str(sd.get("name", "")))
			s.join_order = _int(sd, "order", 0)
			s.cpu_level = Tuning.cpu.clamp_level(_int(sd, "cpu_level", -1))
		s.device_id = -1
		slots.append(s)
	rounds_to_win = clampi(_int(d, "rounds", rounds_to_win), MIN_ROUNDS, MAX_ROUNDS)
	time_index = clampi(_int(d, "time", time_index), 0, time_options.size() - 1)
	var c: Variant = d.get("coop")
	if c is Array and (c as Array).size() == 8:
		coop_structure = clampi(_int_at(c, 0, coop_structure), 0, CoopConfig.Structure.size() - 1)
		coop_enemy_count = clampi(_int_at(c, 1, coop_enemy_count), 1, Tuning.coop.max_enemy_count)
		coop_waves = clampi(_int_at(c, 2, coop_waves), 1, Tuning.coop.max_wave_count + 1)
		coop_enemy_level = Tuning.cpu.clamp_level(_int_at(c, 3, coop_enemy_level))
		coop_roster = clampi(_int_at(c, 4, coop_roster), 0, n)
		coop_ally = c[5] == true
		coop_ally_level = Tuning.cpu.clamp_level(_int_at(c, 6, coop_ally_level))
		coop_ally_char = clampi(_int_at(c, 7, coop_ally_char), 0, n - 1)
	friendly_fire = d.get("ff", friendly_fire) == true
	return true


static func _int(d: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = d.get(key, fallback)
	return v if v is int else fallback


static func _int_at(a: Array, i: int, fallback: int) -> int:
	return a[i] if a[i] is int else fallback


# --- memory (offline, across visits) ---------------------------------------------

func remember() -> void:
	var chars: Array[int] = []
	for s in slots:
		chars.append(s.char_index)
	if is_coop():
		_coop_memory = {
			"chars": chars, "time": time_options[time_index], "structure": coop_structure,
			"enemies": coop_enemy_count, "waves": coop_waves, "enemy_level": coop_enemy_level,
			"roster": coop_roster, "ally": coop_ally, "ally_level": coop_ally_level,
			"ally_char": coop_ally_char, "friendly_fire": friendly_fire,
		}
		return
	_memory = {"rounds": rounds_to_win, "time": time_options[time_index], "chars": chars}
	var cpu := cpu_slot()
	if cpu >= 0:
		_memory["cpu_level"] = slots[cpu].cpu_level


func restore() -> void:
	var m := _coop_memory if is_coop() else _memory
	if m.is_empty():
		return
	var t := time_options.find(int(m.get("time", -999)))
	if t >= 0:
		time_index = t
	var n := MenuHelpers.character_ids().size()
	var chars: Array = m.get("chars", [])
	for i in mini(chars.size(), slots.size()):
		slots[i].char_index = clampi(int(chars[i]), 0, n - 1)
	if not is_coop():
		rounds_to_win = int(m.get("rounds", rounds_to_win))
		var cpu := cpu_slot()
		if cpu >= 0 and m.has("cpu_level"):
			slots[cpu].cpu_level = Tuning.cpu.clamp_level(int(m["cpu_level"]))
		return
	coop_structure = clampi(int(m.get("structure", coop_structure)), 0, CoopConfig.Structure.size() - 1)
	coop_enemy_count = clampi(int(m.get("enemies", coop_enemy_count)), 1, Tuning.coop.max_enemy_count)
	coop_waves = clampi(int(m.get("waves", coop_waves)), 1, Tuning.coop.max_wave_count + 1)
	coop_enemy_level = Tuning.cpu.clamp_level(int(m.get("enemy_level", coop_enemy_level)))
	coop_roster = clampi(int(m.get("roster", coop_roster)), 0, n)
	coop_ally = bool(m.get("ally", coop_ally))
	coop_ally_level = Tuning.cpu.clamp_level(int(m.get("ally_level", coop_ally_level)))
	coop_ally_char = clampi(int(m.get("ally_char", coop_ally_char)), 0, n - 1)
	friendly_fire = bool(m.get("friendly_fire", friendly_fire))
