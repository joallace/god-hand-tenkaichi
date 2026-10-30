class_name OnlineRoom
extends RefCounted
## An open online room on top of a Session (SPEC_ONLINE.md §10): the lobby
## (a LobbyModel, authoritative on the host, mirrored on guests), the room
## phase, the start countdown, who has the pause overlay open and who voted
## for a rematch. No UI: the lobby / results / match scenes read it and call
## `request()`.
##
## Requests (`request(req)`; the host applies its own directly, a guest's
## travel as LOBBY_REQ and the host validates them against the sender):
##   {"op": "join"}                     claim a free slot (lobby phase)
##   {"op": "cmd", "slot", "cmd"}       LobbyModel.Cmd on a slot you own
##   {"op": "pause", "on": bool}        pause overlay open / closed (match)
##   {"op": "rematch", "on": bool}      results: vote for a rematch
##   {"op": "forfeit"}                  versus match: you give up (RollbackDriver.drop_out:
##                                      CPUs take your slots; your team loses
##                                      if no human would be left to play)
##   {"op": "leave_run"}                co-op match: your slots become CPUs
##   {"op": "to_lobby"}                 host only: results -> lobby
## After any change the host broadcasts `state_dict()` (LOBBY_STATE); every
## peer emits `changed`. Each peer is limited to
## Tuning.net.max_local_players_online slots (couch + online: one join
## request per local device, answered in order). Modes: versus (Mode.ONLINE,
## teams / FFA and CPU seats) and co-op (Mode.COOP, up to
## Tuning.net.max_humans humans); a mode switch can move a peer's slots, and
## `local_devices` follows them (_remap_devices).
##
## Starting: when every slot is ready the host counts down
## Tuning.net.lobby_countdown_frames (guests count the same frames from the
## broadcast), then sends MATCH_START (config dict + seed; the host sets the
## browser caps in it when a member is on web, apply_platform_caps). Every peer turns
## it into a MatchConfig, fills in the device of each slot it owns from
## `local_devices`, and emits `match_starting` (Net -> Game.start_match).
## A rematch restarts with the same lobby and a new seed once every human
## peer of the last match voted for it.

enum Phase { LOBBY, MATCH, RESULTS }

const OP_JOIN := "join"
const OP_CMD := "cmd"
const OP_PAUSE := "pause"
const OP_REMATCH := "rematch"
const OP_FORFEIT := "forfeit"
const OP_LEAVE_RUN := "leave_run"
const OP_TO_LOBBY := "to_lobby"
## countdown when no countdown runs.
const NO_COUNTDOWN := -1

## Lobby / phase / countdown / pause / rematch state changed.
signal changed()
signal phase_changed(phase: Phase)
## Start this match now (config localized for this peer, devices filled in).
signal match_starting(config: MatchConfig)
## A peer left the room (name kept for "<name> disconnected").
signal peer_departed(peer: int, peer_name: String)

var session: Session
var model := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
var phase: Phase = Phase.LOBBY
## Frames until the match starts, or NO_COUNTDOWN.
var countdown: int = NO_COUNTDOWN
## Peers with the pause overlay open.
var paused_peers: Array[int] = []
## Results: peers that voted for a rematch.
var rematch_votes: Array[int] = []
## Peers that left during this room's life: peer -> name.
var departed: Dictionary = {}
## Guest: the host's WELCOME arrived (host: always true).
var welcomed := false
## This machine's devices: slot -> [Bindings.Kind, device id].
var local_devices: Dictionary = {}
## The last match's config (shared form, owner peers set).
var last_config: MatchConfig
## The running match's driver (the match scene sets it; host forfeits).
var driver: RollbackDriver

## Devices waiting for the host to give them a slot, in request order
## (each [Bindings.Kind, device id]).
var _pending_devices: Array = []


func _init(s: Session) -> void:
	session = s
	welcomed = s.is_host()
	s.lobby_state_received.connect(_on_lobby_state)
	s.lobby_request_received.connect(_apply)
	s.match_start_received.connect(_on_match_start)
	s.peer_left.connect(_on_peer_left)
	s.peer_joined.connect(_on_peer_joined)
	s.welcomed.connect(_on_welcomed)
	if s.is_host():
		_broadcast()


## Drop the session's signal connections (they keep this room and the
## session alive in a cycle). Net.leave() calls it.
func detach() -> void:
	if session == null:
		return
	for pair: Array in [[session.lobby_state_received, _on_lobby_state],
			[session.lobby_request_received, _apply], [session.match_start_received, _on_match_start],
			[session.peer_left, _on_peer_left], [session.peer_joined, _on_peer_joined],
			[session.welcomed, _on_welcomed]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	session = null
	driver = null


func _on_welcomed(_peer: int) -> void:
	welcomed = true


func is_host() -> bool:
	return session.is_host()


func local_peer() -> int:
	return session.local_peer_id


## Slots this machine owns.
func my_slots() -> Array[int]:
	return model.slots_of(local_peer())


## Guest/host: claim a slot for a local device (one request per device).
func join_local(kind: int, device: int) -> void:
	if phase != Phase.LOBBY or my_slots().size() + _pending_devices.size() >= Tuning.net.max_local_players_online:
		return
	if kind == Bindings.Kind.PAD and (is_pending(kind, device) or slot_of_device(kind, device) >= 0):
		return
	if model.first_free_slot() < 0:
		return  # full as far as we know (a refused join would stay pending)
	_pending_devices.append([kind, device])
	request({"op": OP_JOIN})


## A device that asked for a slot and has none yet.
func is_pending(kind: int, device: int) -> bool:
	for d: Array in _pending_devices:
		if d[0] == kind and (kind == Bindings.Kind.KEYBOARD or d[1] == device):
			return true
	return false


## Slot of a local device, or -1.
func slot_of_device(kind: int, device: int) -> int:
	for slot: int in local_devices:
		var d: Array = local_devices[slot]
		if d[0] == kind and (kind == Bindings.Kind.KEYBOARD or d[1] == device):
			return slot
	return -1


func request(req: Dictionary) -> void:
	if is_host():
		_apply(local_peer(), req)
	else:
		session.send_lobby_request(req)


## Per frame (Net, outside matches): the countdown.
func tick() -> void:
	if phase != Phase.LOBBY or countdown == NO_COUNTDOWN:
		return
	countdown = maxi(countdown - 1, 0)
	if is_host() and countdown == 0:
		start_match()


## Host: start the match from the lobby now (the countdown does it).
func start_match() -> void:
	if not is_host():
		return
	var cfg := model.build_config(randi())
	_begin(cfg.to_dict(), cfg.rng_seed)


## Seconds left on the countdown, rounded up (0 = none).
func countdown_seconds() -> int:
	return ceili(float(maxi(countdown, 0)) / Tuning.match_rules.tick_rate)


## The plain-data form the host broadcasts.
func state_dict() -> Dictionary:
	return {"phase": phase, "model": model.to_dict(), "countdown": countdown,
		"paused": paused_peers.duplicate(), "rematch": rematch_votes.duplicate()}


## Online ms to a peer as seen from here (host: direct; guest: the host
## link for the host, host link + that peer's link for others (unknown, so
## the host's)). -1 = not measured.
func ping_ms(peer: int) -> float:
	if peer == local_peer():
		return 0.0
	return session.rtt_ms(peer if is_host() else Transport.HOST_PEER)


# --- host side --------------------------------------------------------------------

func _apply(peer: int, req: Dictionary) -> void:
	if not is_host():
		return
	var op: Variant = req.get("op")
	var mine := model.slots_of(peer)
	match op:
		OP_JOIN:
			if phase != Phase.LOBBY or mine.size() >= Tuning.net.max_local_players_online:
				return
			var slot := model.join(Bindings.Kind.PAD, -1, peer, session.peer_name(peer))
			if slot < 0:
				if peer == local_peer():
					_pending_devices.pop_front()
				return
			if peer == local_peer() and not _pending_devices.is_empty():
				var d: Array = _pending_devices.pop_front()
				local_devices[slot] = d
				model.slots[slot].device_kind = d[0]
				model.slots[slot].device_id = d[1]
		OP_CMD:
			var slot: Variant = req.get("slot")
			var cmd: Variant = req.get("cmd")
			if phase != Phase.LOBBY or not slot is int or not cmd is int or not slot in mine \
					or cmd < 0 or cmd >= LobbyModel.Cmd.size():
				return
			if model.command(slot, cmd) == LobbyModel.EV_LEAVE and peer == local_peer():
				local_devices.erase(slot)
		OP_PAUSE:
			if phase != Phase.MATCH:
				return
			paused_peers.erase(peer)
			if req.get("on") == true:
				paused_peers.append(peer)
		OP_REMATCH:
			if phase != Phase.RESULTS:
				return
			rematch_votes.erase(peer)
			if req.get("on") == true:
				rematch_votes.append(peer)
			if _rematch_agreed():
				_begin(last_config.to_dict(), randi())
				return
		OP_FORFEIT:
			_forfeit(peer)
			return
		OP_LEAVE_RUN:
			_leave_run(peer)
			return
		OP_TO_LOBBY:
			if peer != local_peer() or phase == Phase.LOBBY:
				return
			_set_phase(Phase.LOBBY)
		_:
			return
	_remap_devices()
	_update_countdown()
	_broadcast()


## Host: broadcast after changing `model` directly (not through request).
func publish() -> void:
	if is_host():
		_update_countdown()
		_broadcast()


func _update_countdown() -> void:
	if phase == Phase.LOBBY and model.all_ready():
		if countdown == NO_COUNTDOWN:
			countdown = Tuning.net.lobby_countdown_frames
	else:
		countdown = NO_COUNTDOWN


## Every human peer of the last match still here and voted.
func _rematch_agreed() -> bool:
	if last_config == null:
		return false
	for p in last_config.players:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			continue
		if departed.has(p.owner_peer) or not p.owner_peer in rematch_votes:
			return false
	return true


func _forfeit(peer: int) -> void:
	if phase != Phase.MATCH or driver == null or driver.director == null or driver.director.is_coop():
		return
	driver.drop_out(peer)


func _leave_run(peer: int) -> void:
	if phase != Phase.MATCH or driver == null or driver.director == null or not driver.director.is_coop():
		return
	driver.drop_out(peer)


func _on_peer_left(peer: int, _reason: int, _last_tick: int) -> void:
	var nm := ""
	for s in model.slots:
		if s.owner_peer == peer:
			nm = s.display_name
	if nm.is_empty():
		nm = "Player %d" % peer
	departed[peer] = nm
	paused_peers.erase(peer)
	rematch_votes.erase(peer)
	if is_host() and phase == Phase.LOBBY:
		model.remove_peer(peer)
		model.unready_all()
	peer_departed.emit(peer, nm)
	if is_host():
		_update_countdown()
		_broadcast()
	changed.emit()


## Peer ids are reused (the lowest free one): a newcomer with a departed
## peer's id is here, not gone (rematch votes, "<name> disconnected").
func _on_peer_joined(peer: int, _peer_name: String) -> void:
	departed.erase(peer)


func _broadcast() -> void:
	session.accepting_joins = phase == Phase.LOBBY
	session.set_lobby_state(state_dict())
	changed.emit()


func _set_phase(p: Phase) -> void:
	if p == phase:
		return
	phase = p
	countdown = NO_COUNTDOWN
	paused_peers.clear()
	rematch_votes.clear()
	if p == Phase.LOBBY:
		model.unready_all()
	if p != Phase.MATCH:
		driver = null
	phase_changed.emit(p)


## Any peer: the match ended (the match scene calls it before results).
func match_finished() -> void:
	if phase != Phase.MATCH:
		return
	_set_phase(Phase.RESULTS)
	if is_host():
		_broadcast()
	else:
		changed.emit()


# --- every peer -----------------------------------------------------------------

func _on_lobby_state(lobby: Dictionary) -> void:
	if is_host():
		return
	var md: Variant = lobby.get("model")
	if md is Dictionary:
		model.apply_dict(md)
	var c: Variant = lobby.get("countdown")
	if c is int:
		countdown = maxi(c, NO_COUNTDOWN)
	paused_peers = _peer_list(lobby.get("paused"))
	rematch_votes = _peer_list(lobby.get("rematch"))
	var p: Variant = lobby.get("phase")
	# MATCH starts with MATCH_START, not with the state broadcast.
	if p is int and p != Phase.MATCH and p >= 0 and p < Phase.size():
		_set_phase(p)
	_claim_pending_slot()
	changed.emit()


## Devices whose slot is no longer ours (a mode switch packed the slots)
## move to our slots without a device, in slot order; the rest are dropped.
func _remap_devices() -> void:
	var mine := my_slots()
	var lost: Array = []
	var keys: Array = local_devices.keys()
	keys.sort()
	for slot: int in keys:
		if not slot in mine:
			lost.append(local_devices[slot])
			local_devices.erase(slot)
	for slot in mine:
		if lost.is_empty():
			break
		if not local_devices.has(slot):
			local_devices[slot] = lost.pop_front()


## Guest: slots the host gave us take the devices we joined with, in order.
func _claim_pending_slot() -> void:
	_remap_devices()
	for slot in my_slots():
		if _pending_devices.is_empty():
			return
		if not local_devices.has(slot):
			local_devices[slot] = _pending_devices.pop_front()
	# The host answers joins in order: with the room full, the rest were refused.
	if model.first_free_slot() < 0 or phase != Phase.LOBBY:
		_pending_devices.clear()


func _on_match_start(config: Dictionary, seed_value: int, _start: Dictionary) -> void:
	if is_host():
		return
	_begin(config, seed_value)


## Turn a MATCH_START into this peer's MatchConfig and announce it.
func _begin(config_dict: Dictionary, seed_value: int) -> void:
	var shared := MatchConfig.from_dict(config_dict)
	if shared == null:
		push_warning("OnlineRoom: invalid match config")
		return
	shared.rng_seed = seed_value
	if is_host():
		# Browser caps when any member is on web (rematches re-pick them).
		shared.apply_platform_caps(session.includes_platform(Protocol.PLATFORM_WEB))
	_set_phase(Phase.MATCH)
	if is_host():
		session.start_match(shared.to_dict(), seed_value)
		_broadcast()
	last_config = shared
	var cfg := MatchConfig.from_dict(shared.to_dict())
	# Lobby slot order = config slot order (co-op renumbers its joined humans
	# from 0), so our devices go to our config slots in order.
	var devices: Array = []
	var keys: Array = local_devices.keys()
	keys.sort()
	for slot: int in keys:
		devices.append(local_devices[slot])
	for p in cfg.players:
		if p.owner_peer == local_peer() and p.input_kind != PlayerSlotConfig.InputKind.CPU and not devices.is_empty():
			var d: Array = devices.pop_front()
			p.device_kind = d[0]
			p.device_id = d[1]
	match_starting.emit(cfg)


static func _peer_list(v: Variant) -> Array[int]:
	var out: Array[int] = []
	if v is Array:
		for x: Variant in v:
			if x is int:
				out.append(x)
	return out
