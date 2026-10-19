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
	check(not o.rows().has(LobbyModel.Row.MODE), "online lobby (versus only for now) has no Game row")
	var h := o.join(Bindings.Kind.PAD, 0, Transport.HOST_PEER, "Host")
	var g := o.join(Bindings.Kind.PAD, -1, 2, "Guest")
	check(o.rows_for(g) == ([LobbyModel.Row.CHARACTER] as Array[int]) and o.rows_for(h).has(LobbyModel.Row.ROUNDS),
			"guests only pick their fighter; the host has the rules")
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
	check(guest.welcomed and guest.model.online and guest.model.slots.size() == 2, "guest mirrors the host's lobby")

	host.join_local(Bindings.Kind.PAD, 0)
	guest.join_local(Bindings.Kind.KEYBOARD, -1)
	_pump(all_s, all_r, 10)
	check(host.my_slots() == ([0] as Array[int]) and host.local_devices.get(0) == [Bindings.Kind.PAD, 0], "host joined slot 0 with pad 0")
	check(guest.my_slots() == ([1] as Array[int]) and guest.local_devices.get(1) == [Bindings.Kind.KEYBOARD, -1],
			"guest got slot 1 and keeps its keyboard locally")
	check(host.model.slots[1].display_name == "Guest" and guest.model.slots[0].display_name == "Host", "names in both lobbies")
	guest.join_local(Bindings.Kind.PAD, 3)
	_pump(all_s, all_r, 10)
	check(host.model.slots_of(2).size() == 1, "a peer can't take a second slot online")

	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.CONFIRM})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.CONFIRM})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.BACK})
	guest.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.DOWN})
	_pump(all_s, all_r, 10)
	check(host.model.slots[1].state == LobbyModel.SlotState.JOINED and guest.model.slots[1].state == LobbyModel.SlotState.JOINED,
			"guest's ready / un-ready applied by the host and mirrored back")
	check(host.model.slots[0].state == LobbyModel.SlotState.JOINED, "guest can't steer the host's slot")
	check(host.model.slots[1].cursor == LobbyModel.Row.CHARACTER, "guest cursor can't leave its fighter row")

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
