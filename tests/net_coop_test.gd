extends Node
## Online co-op end to end (SPEC_ONLINE.md §15 milestone 3, §10.2, §13):
## a host and three guests over a LoopbackNetwork, each with its own Session
## + OnlineRoom, then a MatchDirector + RollbackDriver + MatchEventHub per
## peer in this process.
##   Lobby: versus -> Co-op (joined humans packed), guests join, the room is
##   full so the ally can't be switched on; a guest leaves (a gap in the lobby
##   slots), the ally goes on; everyone readies, countdown -> MATCH_START ->
##   every peer's config has its own device on its renumbered slot.
##   Match 1 (latency / jitter / loss): the online field cap holds on every
##   peer at every frame, a guest's `leave_run` turns its slot into a CPU on
##   every peer at the same tick ("CPU (<name>)"), confirmed checkpoint hashes
##   agree, the run ends -> every room in RESULTS -> rematch votes restart
##   it with the same config and a new seed.
##   Match 2: a guest disconnects mid-run -> CPU_TAKEOVER on every remaining
##   peer, the run goes on, hashes still agree.
## Then a peer id reused by a new guest after one left the lobby must not
## count as departed (rematch votes, "<name> disconnected").
##   godot --headless res://tests/net_coop_test.tscn

const NET_SEED := 21
## OnlineRoom draws match seeds from the global RNG: seeded, the run replays.
const GLOBAL_SEED := 4242
const CONNECT_FRAMES := 300
const PUMP_FRAMES := 10
const LATENCY_MS := 60.0
const JITTER_MS := 15.0
const LOSS_PERCENT := 5.0
const ENEMIES := 5
## Humans play as strong CPUs (scripted local sources) against weak enemies,
## so the run clears in test time.
const HUMAN_CPU_LEVEL := 7
const ENEMY_LEVEL := 0
## Frames before the leave_run / disconnect, and after it for the command.
const FRAMES_BEFORE_LEAVE := 240
const FRAMES_AFTER_LEAVE := 120
## Most frames match 1 may take to end on every peer.
const MAX_RUN_FRAMES := 12000
## Frames match 2 runs after the disconnect.
const FRAMES_AFTER_DISCONNECT := 240

const NAMES := ["Host", "Ann", "Bob", "Cid"]
## Each peer's local device in the lobby (kind, id).
const DEVICES := [[Bindings.Kind.KEYBOARD, -1], [Bindings.Kind.PAD, 4], [Bindings.Kind.PAD, 5], [Bindings.Kind.PAD, 6]]

var _fails := 0
var _net: LoopbackNetwork
var _peers: Array[Peer] = []
var _delay := 0


class Peer:
	var index: int
	var session: Session
	var room: OnlineRoom
	var configs: Array[MatchConfig] = []
	var director: MatchDirector
	var driver: RollbackDriver
	var hub: MatchEventHub
	var ended := false
	## Confirmed checkpoint tick -> hash, every one seen this match.
	var hashes: Dictionary = {}
	## Most fighters on the field after any frame this match.
	var max_field := 0

	func live() -> bool:
		return session.state != Session.State.CLOSED

	func peer_id() -> int:
		return session.local_peer_id


func _ready() -> void:
	seed(GLOBAL_SEED)
	_delay = TimeSync.auto_input_delay(4.0 * LATENCY_MS)  # guest -> host -> guest
	if _check(_test_lobby(), "lobby reached the match on every peer"):
		var cfg := _test_match_one()
		if cfg != null:
			_test_match_two()
	_teardown()
	_test_reused_peer_id()
	print("NET COOP TESTS: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _check(cond: bool, what: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1
	return cond


# --- harness ----------------------------------------------------------------------

func _add_guest(i: int) -> Peer:
	var p := Peer.new()
	p.index = i
	var t := _net.create_client()
	p.session = Session.create_guest(t, NAMES[i])
	p.session.clock = _net.now_ms
	p.room = OnlineRoom.new(p.session)
	_watch_starts(p)
	_net.connect_client(t, _peers[0].session.transport as LoopbackTransport)
	_peers.append(p)
	for f in CONNECT_FRAMES:
		_pump(1)
		if p.session.state == Session.State.CONNECTED and p.room.welcomed:
			break
	_pump(PUMP_FRAMES)
	return p


func _watch_starts(p: Peer) -> void:
	p.room.match_starting.connect(func(c: MatchConfig) -> void: p.configs.append(c))


## Outside a match (what Net does): sessions and rooms; inside one, drivers.
func _pump(frames: int) -> void:
	for f in frames:
		_net.advance_frame()
		for p in _peers:
			if not p.live():
				continue
			if p.driver != null:
				p.driver.advance()
				_after_advance(p)
			else:
				p.session.update()
				p.room.tick()


func _after_advance(p: Peer) -> void:
	p.max_field = maxi(p.max_field, p.director.fighters.size())
	for t: int in p.driver.confirmed_hashes:
		p.hashes[t] = p.driver.confirmed_hashes[t]


func _live_peers() -> Array[Peer]:
	var out: Array[Peer] = []
	for p in _peers:
		if p.live():
			out.append(p)
	return out


## Start a match on every live peer from the config its room announced
## (what the match scene does); local slots play as CpuInputs.
func _start_matches() -> void:
	for p in _live_peers():
		var cfg: MatchConfig = MatchConfig.from_dict(p.configs.back().to_dict())
		p.director = MatchDirector.new()
		add_child(p.director)
		p.hub = MatchEventHub.new()
		add_child(p.hub)
		p.driver = RollbackDriver.new()
		p.driver.auto_run = false
		add_child(p.driver)
		var local := {}
		for ps in cfg.players:
			if ps.input_kind != PlayerSlotConfig.InputKind.CPU and ps.owner_peer == p.peer_id():
				local[ps.slot] = CpuInput.new(HUMAN_CPU_LEVEL)
		p.driver.start(p.director, p.session, cfg, local, _delay, p.hub)
		for slot: int in local:
			(local[slot] as CpuInput).attach(p.director, slot)
		p.room.driver = p.driver
		p.ended = false
		p.hashes = {}
		p.max_field = 0
		var peer := p
		p.hub.confirmed_event.connect(func(_t: int, kind: StringName, _d: Dictionary) -> void:
			if kind == &"match_ended":
				peer.ended = true
				peer.room.match_finished())


func _stop_matches() -> void:
	for p in _peers:
		for n: Node in [p.driver, p.hub, p.director]:
			if n != null:
				remove_child(n)
				n.free()
		p.driver = null
		p.hub = null
		p.director = null
		if p.room != null:
			p.room.driver = null


## Every live peer's confirmed hashes agree on their common ticks (at least
## two shared), without resyncs.
func _hashes_agree(label: String) -> void:
	var live := _live_peers()
	var ref := live[0].hashes
	var common := 0
	var bad: Array = []
	for t: int in ref:
		var all := true
		for p in live:
			if not p.hashes.has(t):
				all = false
			elif p.hashes[t] != ref[t]:
				bad.append([p.peer_id(), t])
		if all:
			common += 1
	_check(bad.is_empty() and common >= 2, "%s: every peer's confirmed checkpoints agree (%d shared) %s"
			% [label, common, str(bad.slice(0, 4))])
	var resyncs := 0
	for p in live:
		resyncs += p.driver.resyncs
	_check(resyncs == 0, "%s: no desync resyncs" % label)


func _field_cap_held(label: String, cap: int) -> void:
	var worst := 0
	for p in _live_peers():
		worst = maxi(worst, p.max_field)
	_check(worst <= cap and worst == cap, "%s: the field filled up to the online cap and never past it (%d / %d)"
			% [label, worst, cap])


## Every live peer applied one CPU_TAKEOVER of `slot`, at the same tick, and
## the slot is a CPU on every peer.
func _takeover_everywhere(slot: int, label: String) -> void:
	var ticks: Array = []
	var cpu := true
	for p in _live_peers():
		cpu = cpu and p.director.controller_for_slot(slot) == MatchDirector.Controller.CPU
		for c in p.director.commands():
			if c["kind"] == MatchDirector.CommandKind.CPU_TAKEOVER and c["slot"] == slot:
				ticks.append(c["tick"])
	_check(cpu, "%s: slot %d is a CPU on every peer" % [label, slot])
	var same := ticks.size() == _live_peers().size()
	for t: int in ticks:
		same = same and t == ticks[0]
	_check(same, "%s: one CPU_TAKEOVER at the same tick on every peer %s" % [label, str(ticks)])


# --- lobby ------------------------------------------------------------------------

func _test_lobby() -> bool:
	_net = LoopbackNetwork.new(NET_SEED)
	var host := Peer.new()
	host.index = 0
	host.session = Session.create_host(_net.create_host(), NAMES[0])
	host.session.clock = _net.now_ms
	host.room = OnlineRoom.new(host.session)
	_watch_starts(host)
	_peers.append(host)
	var ann := _add_guest(1)
	_check(ann.session.state == Session.State.CONNECTED, "first guest connected")

	# Versus first: two seats; switching to co-op packs the joined humans.
	host.room.join_local(DEVICES[0][0], DEVICES[0][1])
	ann.room.join_local(DEVICES[1][0], DEVICES[1][1])
	_pump(PUMP_FRAMES)
	var hm := host.room.model
	hm.slots[0].cursor = LobbyModel.Row.MODE
	host.room.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(PUMP_FRAMES)
	var places := mini(Tuning.net.max_humans, Tuning.net.max_fighters)
	_check(hm.is_coop() and ann.room.model.is_coop() and ann.room.model.slots.size() == places
			and ann.room.my_slots() == ([1] as Array[int]), "host switched the room to Co-op; the guest kept its slot")
	hm.slots[1].cursor = LobbyModel.Row.MODE  # even on the Game row, a guest only steers its fighter
	ann.room.request({"op": OnlineRoom.OP_CMD, "slot": 1, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(PUMP_FRAMES)
	var next_char := 1 % MenuHelpers.character_ids().size()
	_check(hm.is_coop() and hm.slots[1].cursor == LobbyModel.Row.CHARACTER and hm.slots[1].char_index == next_char
			and ann.room.model.slots[1].char_index == next_char, "guests only change their fighter")

	# The run: short Waves, enemies over the online cap.
	hm.coop_structure = CoopConfig.Structure.WAVES
	hm.coop_waves = 1
	hm.coop_enemy_count = ENEMIES
	hm.coop_enemy_level = ENEMY_LEVEL
	hm.coop_ally_level = HUMAN_CPU_LEVEL
	host.room.publish()

	var bob := _add_guest(2)
	var cid := _add_guest(3)
	bob.room.join_local(DEVICES[2][0], DEVICES[2][1])
	_pump(PUMP_FRAMES)
	cid.room.join_local(DEVICES[3][0], DEVICES[3][1])
	_pump(PUMP_FRAMES)
	_check(hm.joined_humans() == places and cid.room.model.joined_humans() == places, "every co-op place taken")
	hm.slots[0].cursor = LobbyModel.Row.ALLY
	host.room.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(PUMP_FRAMES)
	_check(not hm.coop_ally, "the ally can't take a place a human holds")

	# Ann leaves: a gap at lobby slot 1, so lobby slots != config slots.
	ann.session.close()
	_pump(PUMP_FRAMES)
	_check(hm.slots[1].state == LobbyModel.SlotState.EMPTY and bob.room.model.slots[1].state == LobbyModel.SlotState.EMPTY,
			"a guest leaving the lobby frees its slot everywhere")
	host.room.request({"op": OnlineRoom.OP_CMD, "slot": 0, "cmd": LobbyModel.Cmd.RIGHT})
	_pump(PUMP_FRAMES)
	_check(hm.coop_ally and cid.room.model.coop_ally, "ally on once a place is free")
	_check(bob.room.my_slots() == ([2] as Array[int]) and cid.room.my_slots() == ([3] as Array[int])
			and bob.room.local_devices.has(2) and cid.room.local_devices.has(3), "guests keep lobby slots 2 and 3")

	for p in _live_peers():
		for slot in p.room.my_slots():
			p.room.request({"op": OnlineRoom.OP_CMD, "slot": slot, "cmd": LobbyModel.Cmd.CONFIRM})
	_pump(PUMP_FRAMES)
	_check(host.room.countdown > 0 and bob.room.countdown > 0, "everyone ready: the countdown runs")
	_net.latency_ms = LATENCY_MS
	_net.jitter_ms = JITTER_MS
	_net.loss_percent = LOSS_PERCENT
	for f in Tuning.net.lobby_countdown_frames + CONNECT_FRAMES:
		_pump(1)
		if _live_peers().all(func(p: Peer) -> bool: return p.configs.size() == 1):
			break
	if not _live_peers().all(func(p: Peer) -> bool: return p.configs.size() == 1):
		return false
	_check(_live_peers().all(func(p: Peer) -> bool: return p.room.phase == OnlineRoom.Phase.MATCH),
			"every room in the match phase")

	var hc: MatchConfig = host.configs[0]
	var owners: Array[int] = []
	for ps in hc.players:
		owners.append(ps.owner_peer)
	_check(hc.mode == MatchConfig.Mode.COOP and hc.is_online()
			and owners == ([Transport.HOST_PEER, bob.peer_id(), cid.peer_id(), 0] as Array[int])
			and hc.players[3].input_kind == PlayerSlotConfig.InputKind.CPU,
			"config: humans renumbered 0..2, the ally last (owners %s)" % str(owners))
	var devices_ok := true
	var same := true
	for p in _live_peers():
		var c: MatchConfig = p.configs[0]
		var mine := -1
		for ps in c.players:
			if ps.owner_peer == p.peer_id():
				mine = ps.slot
		devices_ok = devices_ok and mine == p.index - 1 + int(p.index == 0) \
				and c.players[mine].device_kind == DEVICES[p.index][0] and c.players[mine].device_id == DEVICES[p.index][1]
		same = same and c.rng_seed == hc.rng_seed and _shared(c) == _shared(hc)
	_check(devices_ok, "each peer's device is on its own renumbered slot")
	_check(same, "every peer got the same match (seed, slots, run)")
	return true


## A config's wire form without the per-machine devices.
static func _shared(c: MatchConfig) -> Dictionary:
	var d := c.to_dict()
	for p: Dictionary in d["players"]:
		p["device_kind"] = 0
		p["device_id"] = -1
	return d


# --- matches ----------------------------------------------------------------------

## Match 1: field cap, leave_run, hashes, the run's end, results, rematch.
## Returns the rematch's shared config (null if it didn't start).
func _test_match_one() -> MatchConfig:
	_start_matches()
	var host := _peers[0]
	var cid := _peers[3]
	var cap := CoopRun.field_cap_for(host.director.config)
	_check(cap == mini(Tuning.coop.online_field_cap, Tuning.coop.field_cap) and cap < Tuning.coop.field_cap,
			"online field cap %d is under the offline cap %d" % [cap, Tuning.coop.field_cap])
	_pump(FRAMES_BEFORE_LEAVE)
	var slot := 2  # Cid: lobby slot 3, config slot 2
	cid.room.request({"op": OnlineRoom.OP_LEAVE_RUN})
	_pump(FRAMES_AFTER_LEAVE)
	_takeover_everywhere(slot, "leave run")
	_check(MatchHud.slot_tag(host.director, slot) == Tuning.hud.text_cpu_takeover % NAMES[3]
			and MatchHud.slot_tag(cid.director, slot) == Tuning.hud.text_cpu_takeover % NAMES[3],
			"HUD tag: '%s'" % MatchHud.slot_tag(host.director, slot))
	_check(MatchHud.slot_tag(host.director, 1) == NAMES[2] and MatchHud.slot_tag(host.director, 3) == "CPU",
			"other tags unchanged (a human's name, the ally's CPU)")

	var frames := 0
	while frames < MAX_RUN_FRAMES and not _live_peers().all(func(p: Peer) -> bool: return p.ended):
		_pump(1)
		frames += 1
	print("match 1 ended after %d more frames (tick %d)" % [frames, host.director.tick])
	_field_cap_held("match 1", cap)
	_hashes_agree("match 1")
	if not _check(_live_peers().all(func(p: Peer) -> bool: return p.ended), "the run ended on every peer (confirmed)"):
		return null
	var cleared := host.director.coop.is_ended() and host.director.last_winner_team == CoopRun.HUMAN_TEAM
	_check(_live_peers().all(func(p: Peer) -> bool: return p.director.last_winner_team == host.director.last_winner_team),
			"every peer saw the same outcome (%s)" % ("cleared" if cleared else "wiped"))
	_pump(PUMP_FRAMES)
	_check(_live_peers().all(func(p: Peer) -> bool: return p.room.phase == OnlineRoom.Phase.RESULTS),
			"every room in RESULTS")

	_stop_matches()
	var first: MatchConfig = host.configs[0]
	for p in _live_peers():
		p.room.request({"op": OnlineRoom.OP_REMATCH, "on": true})
		_pump(PUMP_FRAMES)
	for f in CONNECT_FRAMES:
		if _live_peers().all(func(p: Peer) -> bool: return p.configs.size() == 2):
			break
		_pump(1)
	if not _check(_live_peers().all(func(p: Peer) -> bool: return p.configs.size() == 2),
			"every vote in: the rematch starts on every peer"):
		return null
	var again: MatchConfig = host.configs[1]
	var a := _shared(first)
	var b := _shared(again)
	a.erase("rng_seed")
	b.erase("rng_seed")
	_check(a == b and again.rng_seed != first.rng_seed, "rematch: same config, new seed")
	var all_same := true
	for p in _live_peers():
		all_same = all_same and p.configs[1].rng_seed == again.rng_seed and p.room.phase == OnlineRoom.Phase.MATCH
	_check(all_same, "every peer rematches with the same seed")
	return again


## Match 2: a guest's connection drops mid-run.
func _test_match_two() -> void:
	_start_matches()
	var host := _peers[0]
	var bob := _peers[2]
	_pump(FRAMES_BEFORE_LEAVE)
	var slot := 1  # Bob: lobby slot 2, config slot 1
	bob.session.close()
	remove_child(bob.driver)
	bob.driver.free()
	bob.driver = null
	_pump(FRAMES_AFTER_LEAVE)
	_takeover_everywhere(slot, "disconnect")
	_check(MatchHud.slot_tag(host.director, slot) == Tuning.hud.text_cpu_takeover % NAMES[2],
			"HUD tag after a disconnect: '%s'" % MatchHud.slot_tag(host.director, slot))
	_check(host.room.departed.has(bob.peer_id()) and _peers[3].room.departed.has(bob.peer_id()),
			"every room knows the guest left")
	var t0 := host.director.tick
	_pump(FRAMES_AFTER_DISCONNECT)
	var going := true
	for p in _live_peers():
		going = going and p.director.tick > t0 + FRAMES_AFTER_DISCONNECT / 2 and p.driver.confirmed_tick > t0 \
				and p.director.phase == MatchDirector.Phase.FIGHT
	_check(going, "the run goes on without the guest (tick %d)" % host.director.tick)
	_field_cap_held("match 2", CoopRun.field_cap_for(host.director.config))
	_hashes_agree("match 2")


func _teardown() -> void:
	_stop_matches()
	for p in _peers:
		p.room.detach()
		if p.live():
			p.session.close()
		p.room = null  # its match_starting lambda holds the Peer
		p.configs.clear()
	_peers.clear()


# --- reused peer ids ----------------------------------------------------------------

## A guest leaves the lobby and the next joiner gets its peer id back: that
## peer is here, not departed, so the rematch only waits for its vote.
func _test_reused_peer_id() -> void:
	_net = LoopbackNetwork.new(NET_SEED)
	var host := Peer.new()
	host.session = Session.create_host(_net.create_host(), NAMES[0])
	host.room = OnlineRoom.new(host.session)
	_watch_starts(host)
	_peers.append(host)
	host.room.join_local(DEVICES[0][0], DEVICES[0][1])
	var ann := _add_guest(1)
	var old_id := ann.peer_id()
	ann.session.close()
	_pump(PUMP_FRAMES)
	var bob := _add_guest(2)
	_check(bob.peer_id() == old_id and host.room.departed.has(old_id) == false,
			"a new guest with a reused peer id (%d) is not departed" % bob.peer_id())
	bob.room.join_local(DEVICES[2][0], DEVICES[2][1])
	_pump(PUMP_FRAMES)
	for p in [host, bob]:
		for slot in (p as Peer).room.my_slots():
			(p as Peer).room.request({"op": OnlineRoom.OP_CMD, "slot": slot, "cmd": LobbyModel.Cmd.CONFIRM})
	_pump(Tuning.net.lobby_countdown_frames + PUMP_FRAMES)
	if not _check(host.configs.size() == 1 and bob.configs.size() == 1, "reused id: the match starts"):
		_teardown()
		return
	for p in [host, bob]:
		(p as Peer).room.match_finished()
	_pump(PUMP_FRAMES)
	for p in [host, bob]:
		(p as Peer).room.request({"op": OnlineRoom.OP_REMATCH, "on": true})
		_pump(PUMP_FRAMES)
	_check(host.configs.size() == 2 and bob.configs.size() == 2, "reused id: both votes start the rematch")
	_check(ResultsScreen.match_end_lines({"config": host.configs[0]}, host.room.departed).is_empty(),
			"reused id: results don't call the new guest disconnected")
	_teardown()
