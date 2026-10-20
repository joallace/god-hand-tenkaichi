extends Node
## Team versus and couch + online end to end (SPEC_ONLINE.md §15 milestone 5,
## §10.2, §13, §17): a host and two guests over a LoopbackNetwork, each with
## its own Session + OnlineRoom, then a MatchDirector + RollbackDriver per
## peer in this process.
##   Lobby: the host joins one local player, Ann two (couch + online: one
##   request per device, each device on its own slot), Bob one; the room is
##   then full. Players pick teams, the host moves Bob with the Seat rows and
##   locks teams (Bob can't change his any more); everyone readies ->
##   countdown -> MATCH_START: a 2v2 config (A = host + Ann's first player,
##   B = Ann's second + Bob) where Ann's machine owns two LOCAL slots with
##   her two devices (split screen) and the others are NETWORK.
##   Match (latency / jitter / loss): Bob disconnects -> humans are left on
##   both teams, so his slot becomes a CPU (no forfeit) at one tick on every
##   peer; then Ann forfeits -> her two slots become CPUs and, the host's
##   humans being all on team A, team B forfeits: the match ends with team A
##   winning on both remaining peers; confirmed hashes agree throughout.
##   godot --headless res://tests/net_teams_test.tscn

const NET_SEED := 33
const GLOBAL_SEED := 777
const CONNECT_FRAMES := 300
const PUMP_FRAMES := 10
const LATENCY_MS := 50.0
const JITTER_MS := 10.0
const LOSS_PERCENT := 5.0
## Local players are scripted as weak CPUs so nobody wins before the drops.
const HUMAN_CPU_LEVEL := 0
const FRAMES_BEFORE_DROP := 240
const FRAMES_AFTER_DROP := 180
## Most frames the forfeit may take to end the match everywhere.
const MAX_END_FRAMES := 600

const NAMES := ["Host", "Ann", "Bob"]
## Each peer's local devices (kind, id), in join order.
const DEVICES := [
	[[Bindings.Kind.KEYBOARD, -1]],
	[[Bindings.Kind.PAD, 4], [Bindings.Kind.PAD, 5]],
	[[Bindings.Kind.PAD, 6]],
]
const TEAM_A := 0
const TEAM_B := 1

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
	var ended := false
	var hashes: Dictionary = {}

	func live() -> bool:
		return session.state != Session.State.CLOSED

	func peer_id() -> int:
		return session.local_peer_id


func _ready() -> void:
	seed(GLOBAL_SEED)
	_delay = TimeSync.auto_input_delay(4.0 * LATENCY_MS)  # guest -> host -> guest
	if _check(_test_lobby(), "lobby reached the match on every peer"):
		_test_match()
	_teardown()
	print("NET TEAMS TESTS: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
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
	p.room.match_starting.connect(func(c: MatchConfig) -> void: p.configs.append(c))
	_net.connect_client(t, _peers[0].session.transport as LoopbackTransport)
	_peers.append(p)
	for f in CONNECT_FRAMES:
		_pump(1)
		if p.session.state == Session.State.CONNECTED and p.room.welcomed:
			break
	_pump(PUMP_FRAMES)
	return p


func _pump(frames: int) -> void:
	for f in frames:
		_net.advance_frame()
		for p in _peers:
			if not p.live():
				continue
			if p.driver != null:
				p.driver.advance()
				for t: int in p.driver.confirmed_hashes:
					p.hashes[t] = p.driver.confirmed_hashes[t]
			else:
				p.session.update()
				p.room.tick()


func _live_peers() -> Array[Peer]:
	var out: Array[Peer] = []
	for p in _peers:
		if p.live():
			out.append(p)
	return out


func _cmd(p: Peer, slot: int, cmd: int) -> void:
	p.room.request({"op": OnlineRoom.OP_CMD, "slot": slot, "cmd": cmd})


## `p` moves `slot`'s cursor to `row` (DOWN presses from where it is).
func _cursor_to(p: Peer, slot: int, row: int) -> void:
	for i in 12:
		if p.room.model.slots[slot].cursor == row:
			return
		_cmd(p, slot, LobbyModel.Cmd.DOWN)
		_pump(PUMP_FRAMES)


# --- lobby ------------------------------------------------------------------------

func _test_lobby() -> bool:
	_net = LoopbackNetwork.new(NET_SEED)
	var host := Peer.new()
	host.session = Session.create_host(_net.create_host(), NAMES[0])
	host.session.clock = _net.now_ms
	host.room = OnlineRoom.new(host.session)
	host.room.match_starting.connect(func(c: MatchConfig) -> void: host.configs.append(c))
	_peers.append(host)
	var ann := _add_guest(1)
	var bob := _add_guest(2)
	_check(ann.session.state == Session.State.CONNECTED and bob.session.state == Session.State.CONNECTED,
			"both guests connected")

	for p in _peers:
		for d: Array in DEVICES[p.index]:
			p.room.join_local(d[0], d[1])
		_pump(PUMP_FRAMES)
	var hm := host.room.model
	_check(hm.slots.size() == Tuning.net.max_fighters and hm.first_free_slot() < 0, "four players: the room is full")
	_check(host.room.my_slots() == ([0] as Array[int]) and ann.room.my_slots() == ([1, 2] as Array[int])
			and bob.room.my_slots() == ([3] as Array[int]), "Ann's two devices hold two slots")
	_check(ann.room.local_devices.get(1) == DEVICES[1][0] and ann.room.local_devices.get(2) == DEVICES[1][1]
			and ann.room.slot_of_device(Bindings.Kind.PAD, 5) == 2, "each of Ann's pads drives its own slot")
	bob.room.join_local(Bindings.Kind.PAD, 9)
	_pump(PUMP_FRAMES)
	_check(bob.room.my_slots().size() == 1 and not bob.room.is_pending(Bindings.Kind.PAD, 9),
			"a join into a full room is refused and forgotten")

	# Teams: host and Ann's first player A, Ann's second player B (her own
	# TEAM rows); Bob is moved to B by the host (Seat rows), then teams lock.
	for pair: Array in [[host, 0, 1], [ann, 1, 1], [ann, 2, 2]]:
		var p: Peer = pair[0]
		_cursor_to(p, pair[1], LobbyModel.Row.TEAM)
		for i in pair[2]:
			_cmd(p, pair[1], LobbyModel.Cmd.RIGHT)
		_pump(PUMP_FRAMES)
	_cursor_to(host, 0, LobbyModel.Row.SEAT)
	for i in 3:
		_cmd(host, 0, LobbyModel.Cmd.RIGHT)
	_pump(PUMP_FRAMES)
	_check(hm.seat == 3 and bob.room.model.seat == 3, "host's Seat row on Bob's slot")
	_cursor_to(host, 0, LobbyModel.Row.SEAT_TEAM)
	_cmd(host, 0, LobbyModel.Cmd.RIGHT)
	_cmd(host, 0, LobbyModel.Cmd.RIGHT)
	_pump(PUMP_FRAMES)
	_cursor_to(host, 0, LobbyModel.Row.LOCK_TEAMS)
	_cmd(host, 0, LobbyModel.Cmd.RIGHT)
	_pump(PUMP_FRAMES)
	var teams: Array[int] = []
	for s in bob.room.model.slots:
		teams.append(s.team)
	_check(teams == ([TEAM_A, TEAM_A, TEAM_B, TEAM_B] as Array[int]) and bob.room.model.lock_teams,
			"teams A A B B on every peer, locked (%s)" % str(teams))
	_cursor_to(bob, 3, LobbyModel.Row.TEAM)
	_cmd(bob, 3, LobbyModel.Cmd.RIGHT)
	_pump(PUMP_FRAMES)
	_check(hm.slots[3].team == TEAM_B and hm.slots[3].cursor == LobbyModel.Row.CHARACTER,
			"locked: Bob can't reach his team row")

	for p in _peers:
		for slot in p.room.my_slots():
			_cmd(p, slot, LobbyModel.Cmd.CONFIRM)
	_pump(PUMP_FRAMES)
	_check(host.room.countdown > 0 and ann.room.countdown > 0, "everyone ready, two teams: the countdown runs")
	_net.latency_ms = LATENCY_MS
	_net.jitter_ms = JITTER_MS
	_net.loss_percent = LOSS_PERCENT
	for f in Tuning.net.lobby_countdown_frames + CONNECT_FRAMES:
		_pump(1)
		if _peers.all(func(p: Peer) -> bool: return p.configs.size() == 1):
			break
	if not _peers.all(func(p: Peer) -> bool: return p.configs.size() == 1):
		return false

	var hc: MatchConfig = host.configs[0]
	var owners: Array[int] = []
	var cfg_teams: Array[int] = []
	for ps in hc.players:
		owners.append(ps.owner_peer)
		cfg_teams.append(ps.team)
	_check(hc.mode == MatchConfig.Mode.ONLINE and hc.players.size() == 4
			and owners == ([Transport.HOST_PEER, ann.peer_id(), ann.peer_id(), bob.peer_id()] as Array[int])
			and cfg_teams == ([0, 0, 1, 1] as Array[int]), "config: 2v2, owners %s, teams %s" % [owners, cfg_teams])
	var ac: MatchConfig = MatchConfig.from_dict(ann.configs[0].to_dict()).localize_for_peer(ann.peer_id())
	_check(ac.local_view_slots() == ([1, 2] as Array[int]) and ac.layout() == MatchConfig.Layout.SPLIT_SCREEN,
			"Ann's machine split-screens her two slots")
	_check(ann.configs[0].players[1].device_id == 4 and ann.configs[0].players[2].device_id == 5
			and host.configs[0].players[0].device_kind == Bindings.Kind.KEYBOARD, "each machine filled in its own devices")
	return true


# --- match ------------------------------------------------------------------------

func _start_matches() -> void:
	for p in _live_peers():
		var cfg: MatchConfig = MatchConfig.from_dict(p.configs.back().to_dict())
		p.director = MatchDirector.new()
		add_child(p.director)
		p.driver = RollbackDriver.new()
		p.driver.auto_run = false
		add_child(p.driver)
		var local := {}
		for ps in cfg.players:
			if ps.input_kind != PlayerSlotConfig.InputKind.CPU and ps.owner_peer == p.peer_id():
				local[ps.slot] = CpuInput.new(HUMAN_CPU_LEVEL)
		p.driver.start(p.director, p.session, cfg, local, _delay)
		for slot: int in local:
			(local[slot] as CpuInput).attach(p.director, slot)
		p.room.driver = p.driver
		var peer := p
		p.director.match_ended.connect(func(_w: int) -> void: peer.ended = true)


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
	_check(bad.is_empty() and common >= 2, "%s: confirmed checkpoints agree (%d shared) %s"
			% [label, common, str(bad.slice(0, 4))])
	var resyncs := 0
	for p in live:
		resyncs += p.driver.resyncs
	_check(resyncs == 0, "%s: no desync resyncs" % label)


## Commands of `kind` (and `slot`, when >= 0) applied on every live peer, at
## one tick. Returns that tick (-1 when they differ or one is missing).
func _same_command(kind: int, slot: int) -> int:
	var ticks: Array[int] = []
	for p in _live_peers():
		for c in p.director.commands():
			if c["kind"] == kind and (slot < 0 or c.get("slot", -1) == slot):
				ticks.append(c["tick"])
	if ticks.size() != _live_peers().size():
		return -1
	for t in ticks:
		if t != ticks[0]:
			return -1
	return ticks[0]


func _test_match() -> void:
	var host := _peers[0]
	var ann := _peers[1]
	var bob := _peers[2]
	_start_matches()
	_pump(FRAMES_BEFORE_DROP)
	_check(not host.ended, "the 2v2 is running")

	bob.session.close()
	_pump(FRAMES_AFTER_DROP)
	_check(_same_command(MatchDirector.CommandKind.CPU_TAKEOVER, 3) > 0, "Bob's slot taken over at one tick on host and Ann")
	_check(_same_command(MatchDirector.CommandKind.FORFEIT, -1) < 0 and not host.ended and not ann.ended,
			"humans left on both teams: no forfeit, the match goes on")
	_check(host.director.controller_for_slot(3) == MatchDirector.Controller.CPU
			and ann.director.controller_for_slot(3) == MatchDirector.Controller.CPU, "slot 3 is a CPU everywhere")
	_hashes_agree("after Bob's drop")

	ann.room.request({"op": OnlineRoom.OP_FORFEIT})
	for f in MAX_END_FRAMES:
		_pump(1)
		if host.ended and ann.ended:
			break
	_check(host.ended and ann.ended, "Ann's forfeit ends the match on both peers")
	var t1 := _same_command(MatchDirector.CommandKind.CPU_TAKEOVER, 1)
	var t2 := _same_command(MatchDirector.CommandKind.CPU_TAKEOVER, 2)
	var tf := _same_command(MatchDirector.CommandKind.FORFEIT, -1)
	_check(t1 > 0 and t1 == t2 and t1 == tf, "Ann's slots taken over and team B forfeited at one tick (%d %d %d)" % [t1, t2, tf])
	_check(host.director.last_winner_team == TEAM_A and ann.director.last_winner_team == TEAM_A
			and host.director.end_reason == &"forfeit", "team A (the host's) wins by forfeit everywhere")
	_pump(PUMP_FRAMES * 3)
	_hashes_agree("after the forfeit")


func _teardown() -> void:
	for p in _peers:
		for n: Node in [p.driver, p.director]:
			if n != null:
				remove_child(n)
				n.free()
		p.driver = null
		p.director = null
		if p.room != null:
			p.room.driver = null
			p.room.detach()
		if p.live():
			p.session.close()
		p.room = null
		p.configs.clear()
	_peers.clear()
