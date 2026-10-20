extends Node
## Unified lobby (SPEC_ONLINE.md §10.2, §16 lobby_test): LobbyModel rules and
## wire form, and two OnlineRooms (host + guest) over LoopbackTransport:
## joins, guest commands applied by the host, host-only rules, un-ready on a
## rule change, countdown -> MATCH_START on both, rematch, back to lobby, a
## guest leaving. Then the Lobby scene hosting through Net with a guest.
## Run as a scene:  godot --headless res://tests/lobby_test.tscn

const MAX_PUMP := 300

var _fails := 0
var _net: LoopbackNetwork


func _ready() -> void:
	_test_model_modes()
	_test_model_wire()
	_test_model_online_coop()
	_test_model_online_mode_switch()
	_test_model_teams()
	_test_binding_profiles()
	_test_model_carry_coop()
	_test_rooms()
	await _test_scene_hosting()
	print("LOBBY %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


# --- model --------------------------------------------------------------------

func _test_model_modes() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	check(m.rows().has(LobbyModel.Row.MODE), "local lobby has a Game (mode) row")
	var a := m.join(Bindings.Kind.PAD, 0)
	m.slots[a].char_index = 1
	m.slots[a].cursor = LobbyModel.Row.MODE
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.mode == MatchConfig.Mode.VERSUS_CPU and m.cpu_slot() == 1, "Game row -> Versus CPU adds the CPU slot")
	check(m.slots[a].state == LobbyModel.SlotState.JOINED and m.slots[a].char_index == 1
			and m.slots[a].device_id == 0, "joined human keeps slot, device and pick across a mode switch")
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.is_coop() and m.rows().has(LobbyModel.Row.ENEMY_COUNT), "Game row -> Co-op shows the run rows")
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.mode == MatchConfig.Mode.LOCAL_VERSUS and m.cpu_slot() < 0, "Game row wraps back to Versus")
	var o := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	check(o.rows().has(LobbyModel.Row.MODE) and o.modes() == LobbyModel.ONLINE_MODES
			and LobbyModel.ONLINE_MODES.has(MatchConfig.Mode.COOP), "online lobby's Game row: Versus / Co-op")
	var h := o.join(Bindings.Kind.PAD, 0, Transport.HOST_PEER, "Host")
	var g := o.join(Bindings.Kind.PAD, -1, 2, "Guest")
	check(o.rows_for(g) == ([LobbyModel.Row.CHARACTER, LobbyModel.Row.TEAM] as Array[int])
			and o.rows_for(h).has(LobbyModel.Row.ROUNDS), "guests only pick their fighter and team; the host has the rules")
	o.command(g, LobbyModel.Cmd.CONFIRM)
	o.slots[h].cursor = LobbyModel.Row.ROUNDS
	o.command(h, LobbyModel.Cmd.RIGHT)
	check(o.slots[g].state == LobbyModel.SlotState.JOINED, "a host rule change un-readies the guest")
	var cfg := o.build_config(5)
	check(cfg.mode == MatchConfig.Mode.ONLINE and cfg.players[1].owner_peer == 2 and cfg.players[1].display_name == "Guest"
			and cfg.is_online() and cfg.rng_seed == 5, "online config carries owners, names and the seed")


func _test_model_wire() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.COOP)
	m.join(Bindings.Kind.KEYBOARD, -1)
	m.coop_ally = true
	m.coop_waves = 3
	m.coop_structure = CoopConfig.Structure.WAVES
	var copy := LobbyModel.new()
	check(copy.apply_dict(m.to_dict()), "apply_dict accepts to_dict")
	check(copy.to_dict() == m.to_dict(), "wire form round-trips")
	check(not copy.apply_dict({"slots": "x", "mode": 1}) and not copy.apply_dict({}), "malformed lobby refused")
	check(copy.apply_dict({"mode": 0, "slots": [{"type": 9, "char": -4, "cursor": 99, "name": 5}, 3]})
			and copy.slots.size() == 2, "junk slot fields are clamped, not fatal")


## An online lobby switched to Co-op by its host (Game row).
func _online_coop_lobby() -> LobbyModel:
	var o := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	var h := o.join(Bindings.Kind.KEYBOARD, -1, Transport.HOST_PEER, "Host")
	o.slots[h].cursor = LobbyModel.Row.MODE
	o.command(h, LobbyModel.Cmd.RIGHT)
	return o


func _test_model_online_coop() -> void:
	var o := _online_coop_lobby()
	var places := mini(Tuning.net.max_humans, Tuning.net.max_fighters)
	check(o.is_coop() and o.slots.size() == places and o.cpu_slot() < 0
			and o.slots.all(func(s: LobbyModel.Slot) -> bool: return s.type == LobbyModel.SlotType.HUMAN),
			"online co-op: %d human slots, no CPU slot" % places)
	var guests: Array[int] = []
	for i in places - 1:
		guests.append(o.join(Bindings.Kind.PAD, -1, Transport.HOST_PEER + 1 + i, "G%d" % i))
	check(not guests.has(-1) and o.joined_humans() == places and o.first_free_slot() < 0,
			"every place can take a human with the ally off")
	check(o.rows_for(0).has(LobbyModel.Row.MODE) and o.rows_for(0).has(LobbyModel.Row.ALLY),
			"online co-op: the host has the Game row and the run rows")
	check(o.rows_for(guests[0]) == ([LobbyModel.Row.CHARACTER] as Array[int]), "online co-op: guests only pick their fighter")
	o.slots[0].cursor = LobbyModel.Row.ALLY
	o.command(0, LobbyModel.Cmd.RIGHT)
	check(not o.coop_ally, "the ally can't be switched on with every place taken by a human")
	o.leave(guests[0])  # a gap at slot 1
	o.command(0, LobbyModel.Cmd.RIGHT)
	check(o.coop_ally and o.human_capacity() == Tuning.net.max_fighters - 1, "ally on once a place is free")
	check(o.first_free_slot() < 0 and o.join(Bindings.Kind.PAD, -1, Transport.HOST_PEER + places, "Late") < 0,
			"ally on: only %d humans can join" % (Tuning.net.max_fighters - 1))

	var cfg := o.build_config(9)
	var owners: Array[int] = []
	var slots_ok := true
	for i in cfg.players.size():
		var p := cfg.players[i]
		slots_ok = slots_ok and p.slot == i and p.team == 0
		if p.input_kind != PlayerSlotConfig.InputKind.CPU:
			owners.append(p.owner_peer)
	var expected: Array[int] = [Transport.HOST_PEER]
	for i in range(1, guests.size()):
		expected.append(o.slots[guests[i]].owner_peer)
	check(cfg.mode == MatchConfig.Mode.COOP and cfg.is_online() and cfg.rng_seed == 9 and cfg.coop != null,
			"online co-op config is online, with its run")
	check(slots_ok and owners == expected and cfg.players.size() == expected.size() + 1,
			"joined humans renumbered from 0 in slot order, all on team 0 (owners %s)" % str(owners))
	check(cfg.players[1].display_name == o.slots[guests[1]].display_name and cfg.player_tag(1) == "G1",
			"renumbered slots keep their names")
	var ally := cfg.players[cfg.players.size() - 1]
	check(ally.input_kind == PlayerSlotConfig.InputKind.CPU and ally.owner_peer == 0 and ally.cpu_level == o.coop_ally_level
			and cfg.coop.ally_enabled, "the CPU ally comes last, owned by nobody")

	var copy := LobbyModel.new()
	check(copy.apply_dict(o.to_dict()) and copy.to_dict() == o.to_dict(), "online co-op lobby round-trips its wire form")
	check(copy.online and copy.is_coop() and copy.coop_ally and copy.slots.size() == places
			and copy.slots[1].state == LobbyModel.SlotState.EMPTY and copy.slots_of(o.slots[guests[1]].owner_peer) == [guests[1]],
			"the mirror keeps the gap, the owners and the ally")
	var mine := cfg.to_dict()
	var mirrored := copy.build_config(9).to_dict()
	for d: Dictionary in [mine, mirrored]:
		for p: Dictionary in d["players"]:
			p["device_kind"] = 0  # devices stay on the machine that owns the slot
			p["device_id"] = -1
	check(mine == mirrored, "a mirror builds the same config apart from devices")


func _test_model_online_mode_switch() -> void:
	var o := _online_coop_lobby()
	var a := o.join(Bindings.Kind.PAD, -1, 2, "Ann")
	var b := o.join(Bindings.Kind.PAD, -1, 3, "Bob")
	o.slots[a].char_index = 1
	o.command(a, LobbyModel.Cmd.CONFIRM)
	o.command(b, LobbyModel.Cmd.CONFIRM)
	o.slots[0].cursor = LobbyModel.Row.MODE
	o.command(0, LobbyModel.Cmd.RIGHT)
	check(o.mode == MatchConfig.Mode.ONLINE and o.slots.size() == Tuning.net.max_fighters, "co-op -> versus: max_fighters slots")
	check(o.slots[0].owner_peer == Transport.HOST_PEER and o.slots[1].owner_peer == 2 and o.slots[1].char_index == 1
			and o.slots_of(3) == ([2] as Array[int]), "every human keeps a versus slot (and their pick), in order")
	check(o.slots.all(func(s: LobbyModel.Slot) -> bool: return s.state != LobbyModel.SlotState.READY),
			"a mode switch un-readies everyone")
	o.command(0, LobbyModel.Cmd.RIGHT)
	check(o.is_coop() and o.joined_humans() == 3 and o.slots[1].owner_peer == 2 and o.slots[1].display_name == "Ann",
			"versus -> co-op keeps the joined humans")
	check(o.first_free_slot() == 3, "the free co-op slots follow the joined ones")


## Team versus: TEAM rows, seats (CPUs), the start rule, config teams.
func _test_model_teams() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	check(m.team_mode() and m.slots.size() == Tuning.net.max_fighters, "local versus has max_fighters slots")
	var a := m.join(Bindings.Kind.PAD, 0)
	m.command(a, LobbyModel.Cmd.CONFIRM)
	check(not m.all_ready() and not m.teams_ok(), "one fighter can't start")
	var cfg1v1 := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	cfg1v1.join(Bindings.Kind.PAD, 0)
	cfg1v1.join(Bindings.Kind.PAD, 1)
	for i in 2:
		cfg1v1.command(i, LobbyModel.Cmd.CONFIRM)
	var c := cfg1v1.build_config(1)
	check(cfg1v1.all_ready() and c.players.size() == 2 and c.players.all(func(p: PlayerSlotConfig) -> bool: return p.team == -1),
			"a plain 1v1 builds two own-team slots (empty slots left out)")
	# Host seats a CPU in slot 2 and puts it with player 1 on team A; slot 1 joins team B.
	m.command(a, LobbyModel.Cmd.BACK)
	m.slots[a].cursor = LobbyModel.Row.SEAT
	m.command(a, LobbyModel.Cmd.RIGHT)
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.seat == 2 and m.rows().has(LobbyModel.Row.SEAT_TYPE) and not m.rows().has(LobbyModel.Row.SEAT_TEAM),
			"Seat row picks slot 3 (empty: Seat is Open/CPU, no team)")
	m.slots[a].cursor = LobbyModel.Row.SEAT_TYPE
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.slots[2].type == LobbyModel.SlotType.CPU and m.slots[2].state == LobbyModel.SlotState.READY
			and m.cpu_target() == 2 and m.rows().has(LobbyModel.Row.CPU_LEVEL), "an empty seat becomes a ready CPU with CPU rows")
	m.slots[a].cursor = LobbyModel.Row.CPU_LEVEL
	var lvl := m.slots[2].cpu_level
	m.command(a, LobbyModel.Cmd.LEFT if lvl > 0 else LobbyModel.Cmd.RIGHT)
	check(m.slots[2].cpu_level != lvl, "CPU level row edits the seated CPU")
	m.slots[a].cursor = LobbyModel.Row.SEAT_TEAM
	m.command(a, LobbyModel.Cmd.RIGHT)
	m.slots[a].cursor = LobbyModel.Row.TEAM
	m.command(a, LobbyModel.Cmd.RIGHT)
	check(m.slots[2].team == 0 and m.slots[a].team == 0, "seat team and own team set to A")
	m.command(a, LobbyModel.Cmd.CONFIRM)
	check(not m.all_ready(), "player + CPU on one team: no opponent")
	var b := m.join(Bindings.Kind.PAD, 1)
	check(b == 1, "the next human takes the free slot before the CPU's")
	m.slots[b].cursor = LobbyModel.Row.TEAM
	m.command(b, LobbyModel.Cmd.RIGHT)
	m.command(b, LobbyModel.Cmd.RIGHT)
	m.command(b, LobbyModel.Cmd.CONFIRM)
	check(m.slots[b].team == 1 and m.all_ready(), "a second team: the match can start")
	var cfg := m.build_config(3)
	var teams := {}
	for p in cfg.players:
		teams[p.slot] = p.team
	check(cfg.players.size() == 3 and teams == {0: 0, 1: 1, 2: 0}
			and cfg.players[2].input_kind == PlayerSlotConfig.InputKind.CPU, "config: A = team 0, B = team 1, CPU on A")
	m.slots[b].team = LobbyModel.TEAM_FFA
	m.slots[0].team = LobbyModel.TEAM_FFA
	m.slots[2].team = 1
	var t2 := m.config_teams()
	check(t2 == {0: 0, 1: 1, 2: 2}, "FFA slots get their own team ids next to a named team")
	m.seat = 2
	m.slots[0].cursor = LobbyModel.Row.SEAT_TYPE
	m.slots[0].state = LobbyModel.SlotState.JOINED
	m.command(0, LobbyModel.Cmd.RIGHT)
	check(m.slots[2].type == LobbyModel.SlotType.HUMAN and m.slots[2].state == LobbyModel.SlotState.EMPTY,
			"Seat is -> Open removes the CPU")
	m.seat = 1
	m.fix_cursors()
	m.command(0, LobbyModel.Cmd.RIGHT)
	check(m.slots[1].type == LobbyModel.SlotType.HUMAN and m.slots[1].state != LobbyModel.SlotState.EMPTY,
			"a joined human's seat can't become a CPU")
	var o := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	o.join(Bindings.Kind.PAD, 0, Transport.HOST_PEER, "Host")
	o.slots[0].team = 1
	o.lock_teams = true
	o.seat = 3
	var copy := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	check(copy.apply_dict(o.to_dict()) and copy.slots[0].team == 1 and copy.lock_teams and copy.seat == 3,
			"teams, lock and seat go over the wire")


## Four local players (pads + keyboards, a slot gap) read the Bindings
## profiles the lobby showed them, and a real local match runs with them.
func _test_binding_profiles() -> void:
	var kinds := [Bindings.Kind.PAD, Bindings.Kind.KEYBOARD, Bindings.Kind.PAD, Bindings.Kind.KEYBOARD]
	check(Bindings.profile_for(kinds, 1) == 1 and Bindings.profile_for(kinds, 3) == 0
			and Bindings.profile_for([Bindings.Kind.PAD, Bindings.Kind.PAD, Bindings.Kind.PAD], 2) == Bindings.SLOT_COUNT - 1,
			"P2 keeps its profile; a later keyboard player takes the free layout, later pads the last profile")
	var m := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	m.join(Bindings.Kind.PAD, 0)
	m.join(Bindings.Kind.KEYBOARD, -1)
	m.join(Bindings.Kind.PAD, 1)
	m.join(Bindings.Kind.KEYBOARD, -1)
	m.slots[2].team = 0
	m.slots[3].team = 0
	m.leave(1)
	var cfg := m.build_config(9)
	var profiles: Array[int] = []
	for p in cfg.players:
		profiles.append(cfg.binding_profile(p.slot))
	check(profiles == ([0, 1, 0] as Array[int]), "config profiles by local order: pad P1, pad P3, keyboard A (%s)" % str(profiles))
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in 30:
		d.step()
	check(d.tick == 30 and d.fighters.size() == 3, "a local match with players in slots 0, 2 and 3 runs")
	remove_child(d)
	d.free()


func _test_model_carry_coop() -> void:
	var local := LobbyModel.new(MatchConfig.Mode.COOP)
	local.join(Bindings.Kind.KEYBOARD, -1)
	local.coop_structure = CoopConfig.Structure.WAVES
	local.coop_waves = 2
	local.coop_enemy_count = 7
	local.coop_enemy_level = 1
	local.coop_roster = 1
	local.coop_ally = true
	local.coop_ally_level = 2
	local.friendly_fire = true
	var room := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	room.carry_rules_from(local)
	check(room.online and room.is_coop() and room.slots.size() == mini(Tuning.net.max_humans, Tuning.net.max_fighters)
			and room.nobody_joined(), "opening a room from local co-op gives an online co-op lobby")
	var a := local.build_config(4)
	var b := room.build_config(4)
	check(a.coop.to_dict() == b.coop.to_dict() and a.friendly_fire == b.friendly_fire
			and a.round_time_seconds == b.round_time_seconds, "the room keeps the run setup")
	var versus := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	var room2 := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	room2.carry_rules_from(versus)
	check(room2.mode == MatchConfig.Mode.ONLINE, "opening a room from local versus gives online versus")


# --- rooms over loopback ---------------------------------------------------------

func _pump(sessions: Array, rooms: Array, frames: int = 1) -> void:
	for i in frames:
		_net.advance_frame()
		for s: Session in sessions:
			s.update()
		for r: OnlineRoom in rooms:
			r.tick()


func _test_rooms() -> void:
	_net = LoopbackNetwork.new(3)
	var ht := _net.create_host()
	var gt := _net.create_client()
	var hs := Session.create_host(ht, "Host")
	var gs := Session.create_guest(gt, "Guest")
	_net.connect_client(gt, ht)
	for s in [hs, gs]:
		s.clock = _net.now_ms
	var host := OnlineRoom.new(hs)
	var guest := OnlineRoom.new(gs)
	var all_s := [hs, gs]
	var all_r := [host, guest]
	for i in MAX_PUMP:
		_pump(all_s, all_r)
		if gs.state == Session.State.CONNECTED:
			break
	_pump(all_s, all_r, 5)
	check(guest.welcomed and guest.model.online and guest.model.slots.size() == Tuning.net.max_fighters,
			"guest mirrors the host's lobby")

	host.join_local(Bindings.Kind.PAD, 0)
	guest.join_local(Bindings.Kind.KEYBOARD, -1)
	_pump(all_s, all_r, 10)
	check(host.my_slots() == ([0] as Array[int]) and host.local_devices.get(0) == [Bindings.Kind.PAD, 0], "host joined slot 0 with pad 0")
	check(guest.my_slots() == ([1] as Array[int]) and guest.local_devices.get(1) == [Bindings.Kind.KEYBOARD, -1],
			"guest got slot 1 and keeps its keyboard locally")
	check(host.model.slots[1].display_name == "Guest" and guest.model.slots[0].display_name == "Host", "names in both lobbies")
	# Couch + online: a second local device takes a second slot, then leaves.
	guest.join_local(Bindings.Kind.PAD, 3)
	guest.join_local(Bindings.Kind.PAD, 3)
	_pump(all_s, all_r, 10)
	check(host.model.slots_of(2) == ([1, 2] as Array[int]) and guest.local_devices.get(2) == [Bindings.Kind.PAD, 3]
			and guest.slot_of_device(Bindings.Kind.PAD, 3) == 2, "a guest's second device gets its own slot (once)")
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 2, "cmd": LobbyModel.Cmd.BACK})
	_pump(all_s, all_r, 10)
	check(host.model.slots_of(2) == ([1] as Array[int]) and not guest.local_devices.has(2)
			and guest.local_devices.get(1) == [Bindings.Kind.KEYBOARD, -1], "the second local player leaves; the first keeps its device")

	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.CONFIRM})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.CONFIRM})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.BACK})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.DOWN})
	_pump(all_s, all_r, 10)
	check(host.model.slots[1].state == LobbyModel.SlotState.JOINED and guest.model.slots[1].state == LobbyModel.SlotState.JOINED,
			"guest's ready / un-ready applied by the host and mirrored back")
	check(host.model.slots[0].state == LobbyModel.SlotState.JOINED, "guest can't steer the host's slot")
	check(host.model.slots[1].cursor == LobbyModel.Row.TEAM, "guest cursor goes from its fighter to its team row")
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.DOWN})
	_pump(all_s, all_r, 10)
	check(host.model.slots[1].cursor == LobbyModel.Row.CHARACTER, "and wraps there: the rules are the host's")
	host.model.lock_teams = true
	host.model.fix_cursors()
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.DOWN})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(all_s, all_r, 10)
	check(host.model.slots[1].cursor == LobbyModel.Row.CHARACTER and host.model.slots[1].team == LobbyModel.TEAM_FFA,
			"locked teams: the guest can't reach its team row")
	host.model.lock_teams = false
	host.publish()

	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.CONFIRM})
	host.model.slots[0].cursor = LobbyModel.Row.TIMER
	_pump(all_s, all_r, 10)
	host.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(all_s, all_r, 10)
	check(guest.model.slots[1].state == LobbyModel.SlotState.JOINED and guest.model.time_index == host.model.time_index,
			"host rule change reaches the guest and un-readies it")

	var started: Array = [[], []]
	host.match_starting.connect(func(c: MatchConfig) -> void: started[0].append(c))
	guest.match_starting.connect(func(c: MatchConfig) -> void: started[1].append(c))
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.CONFIRM})
	host.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.CONFIRM})
	_pump(all_s, all_r, 10)
	check(host.countdown > 0 and guest.countdown > 0 and absi(host.countdown - guest.countdown) <= 10,
			"countdown runs on host and guest")
	check(not hs.accepting_joins or host.phase == OnlineRoom.Phase.LOBBY, "joins open while in the lobby")
	_pump(all_s, all_r, Tuning.net.lobby_countdown_frames + 10)
	check(started[0].size() == 1 and started[1].size() == 1, "MATCH_START starts the match on both peers")
	if started[0].size() == 1 and started[1].size() == 1:
		var hc: MatchConfig = started[0][0]
		var gc: MatchConfig = started[1][0]
		check(hc.rng_seed == gc.rng_seed and hc.players.size() == 2 and gc.players[1].owner_peer == 2,
				"both peers got the same match (seed, owners)")
		check(gc.players[1].device_kind == Bindings.Kind.KEYBOARD and hc.players[0].device_id == 0,
				"each peer filled in its own device")
		var a := hc.to_dict()
		var b := gc.to_dict()
		for d: Dictionary in [a, b]:
			for p: Dictionary in d["players"]:
				p["device_kind"] = 0
				p["device_id"] = -1
		check(a == b, "configs equal apart from local devices")
	check(host.phase == OnlineRoom.Phase.MATCH and guest.phase == OnlineRoom.Phase.MATCH and not hs.accepting_joins,
			"room in match phase, joins closed")

	# Results: rematch needs both votes.
	host.match_finished()
	guest.match_finished()
	_pump(all_s, all_r, 5)
	host.request({"op": OnlineRoom.OP_REMATCH, "on": true})
	_pump(all_s, all_r, 5)
	check(started[0].size() == 1 and guest.rematch_votes == ([1] as Array[int]), "one vote: no rematch yet, guest sees it")
	guest.request({"op": OnlineRoom.OP_REMATCH, "on": true})
	_pump(all_s, all_r, 10)
	check(started[0].size() == 2 and started[1].size() == 2, "both votes: rematch starts everywhere")

	host.match_finished()
	guest.match_finished()
	guest.request({"op": OnlineRoom.OP_TO_LOBBY})
	_pump(all_s, all_r, 5)
	check(host.phase == OnlineRoom.Phase.RESULTS, "only the host can go back to the lobby")
	host.request({"op": OnlineRoom.OP_TO_LOBBY})
	_pump(all_s, all_r, 5)
	check(guest.phase == OnlineRoom.Phase.LOBBY and hs.accepting_joins
			and host.model.slots[1].state == LobbyModel.SlotState.JOINED, "back to the lobby: everyone un-readied")

	gs.close()
	_pump([hs], [host], 10)
	check(host.model.slots[1].state == LobbyModel.SlotState.EMPTY and host.departed.has(2),
			"a guest leaving frees its slot")
	host.detach()
	guest.detach()
	hs.close()


# --- scene ----------------------------------------------------------------------

func _test_scene_hosting() -> void:
	_net = LoopbackNetwork.new(4)
	Net.auto_pump = false
	var ht := _net.create_host()
	Net.start_host(ht)
	var gt := _net.create_client()
	var gs := Session.create_guest(gt, "Rival", {"content_hash": ContentHash.compute()})
	var guest := OnlineRoom.new(gs)
	_net.connect_client(gt, ht)
	var lobby := (load(Game.SCENE_LOBBY) as PackedScene).instantiate() as Lobby
	lobby.auto_start = false
	add_child(lobby)
	for i in MAX_PUMP:
		_net.advance_frame()
		Net.update()
		gs.update()
		if gs.state == Session.State.CONNECTED:
			break
	check(gs.state == Session.State.CONNECTED, "guest gets into the hosted room")
	check(lobby.is_online() and lobby.model == Net.room.model, "lobby scene draws the room's model")
	lobby.join(Bindings.Kind.PAD, 0)
	guest.join_local(Bindings.Kind.PAD, 0)
	for i in 10:
		_net.advance_frame()
		Net.update()
		gs.update()
	await get_tree().process_frame
	var header: Label = lobby._ui[1]["header"]
	var device: Label = lobby._ui[1]["device"]
	check(header.text == "RIVAL" and device.text.begins_with("Online"), "remote slot shows the guest's name and Online")
	check(lobby._room_label.text.begins_with("Hosting"), "top bar says Hosting")
	Net.room.model.slots[0].cursor = LobbyModel.Row.TIMER
	var time_before := Net.room.model.time_index
	lobby._command(0, LobbyModel.Cmd.RIGHT)
	for i in 5:
		_net.advance_frame()
		Net.update()
		gs.update()
	check(guest.model.time_index == Net.room.model.time_index and Net.room.model.time_index != time_before,
			"host's rule change in the scene reaches the guest")
	lobby.close_room()
	check(not lobby.is_online() and lobby.model != null and not Net.is_online(), "Close room returns to the local lobby")
	lobby.queue_free()
	guest.detach()
	gs.close()
	Net.leave()
	Net.auto_pump = true
	await get_tree().process_frame
