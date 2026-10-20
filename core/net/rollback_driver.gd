class_name RollbackDriver
extends Node
## Drives a MatchDirector online with rollback (SPEC_ONLINE.md §7, §8, §13).
## Every peer runs the whole sim; remote slots are predicted from the
## Session's InputHistory and re-simulated when the real frames differ.
##
## Setup (before anything ticks):
##   var drv := RollbackDriver.new()
##   add_child(drv)
##   drv.start(director, session, config, local_sources, input_delay, hub)
## `config` is the shared MatchConfig (owner_peer set on human slots); it is
## localized for this peer. `local_sources` = {slot: InputSource} for the
## slots this machine owns (devices; tests use scripted sources). The
## director must not be set up yet: start() installs a source_factory so
## every human slot (local ones too) reads the history through NetworkInput,
## because a resim must replay what was recorded, not poll the pad again.
##
## Per frame (`advance()`, from _physics_process when `auto_run`, or tests):
##   1. pump the session; collect mispredictions, commands, hashes, resyncs
##   2. roll back to the earliest wrong tick (hub.rollback_to, load_state,
##      re-step with director.resimulating = true)
##   3. unless stalled (too far past the oldest unconfirmed remote input, or
##      TimeSync asks to wait): sample local slots for tick + 1 + delay,
##      step, snapshot (up to `ticks` steps when catching up)
##   4. advance confirmed_tick, hub.confirm_through, HASH every
##      checksum_interval confirmed ticks; send
##
## Desync (§8): guests send HASH for confirmed checkpoints; the host compares
## with its own, and on a mismatch writes a dump and sends RESYNC with its
## confirmed snapshot; the guest dumps its own state at that tick, loads the
## host's and re-simulates to the present. After max_resyncs_per_match the
## match is aborted (`aborted(&"desync")`).
##
## Disconnect (§13, host): a peer that leaves has its slots cut at the last
## tick the host confirmed for it: versus -> FORFEIT of its team, co-op ->
## CPU_TAKEOVER at the co-op ally level. The cut slots stop counting for
## stalls and confirmation on every peer once the command is known.
##
## Pause (§10.3): the sim never pauses online. A local PAUSE press emits
## `pause_pressed(slot)`; while `local_paused` the local slots send neutral
## frames.

signal pause_pressed(slot: int)
## Host: a guest's checkpoint hash differed (a RESYNC was sent).
signal desync_detected(peer: int, tick: int)
## Guest: a RESYNC from the host was applied.
signal resynced(tick: int)
## The match cannot go on (&"desync", &"host_left").
signal aborted(reason: StringName)

## Run advance() from _physics_process (off in tests that step by hand).
var auto_run := true
var director: MatchDirector
var session: Session
var hub: MatchEventHub
var input_delay: int = 0
## Local slots send neutral frames (pause overlay open).
var local_paused := false
## Every slot's input is final up to here; events/hashes act on it.
var confirmed_tick: int = 0
var is_aborted := false
## Where desync dumps go (tests point it at a temp dir).
var dump_dir := "user://desync"

## Debug stats (net overlay, tests).
var rollbacks: int = 0
var rollback_ticks: int = 0
var stall_frames: int = 0
var resyncs: int = 0
## Consecutive frames stalled (the "Waiting for <name>…" banner).
var stalled_for: int = 0
## Checkpoint tick -> StateHash of the confirmed state.
var confirmed_hashes: Dictionary = {}

var _local: Dictionary = {}  # slot -> InputSource (devices)
## Human slots owned elsewhere (what stalls and confirmation wait on).
var _remote_slots: Array[int] = []
## Every human slot.
var _human_slots: Array[int] = []
## slot -> first tick it no longer needs input (cut by a command).
var _cut: Dictionary = {}
var _snapshots: Dictionary = {}  # tick -> save_state (rollback ring)
var _checkpoints: Dictionary = {}  # checkpoint tick -> confirmed save_state
var _pending_guest_hashes: Array = []  # host: [peer, tick, hash] not yet comparable
var _rollback_to: int = -1
var _frame: int = 0
var _local_prev: Dictionary = {}  # slot -> held mask of the last sampled frame
## Host: peers whose slots drop_out_commands already took out.
var _out_peers: Array[int] = []


func start(d: MatchDirector, s: Session, config: MatchConfig, local_sources: Dictionary,
		delay: int, p_hub: MatchEventHub = null) -> void:
	director = d
	session = s
	hub = p_hub
	input_delay = delay
	_local = local_sources
	config.localize_for_peer(session.local_peer_id)
	var owners := {}
	for p in config.players:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			continue
		owners[p.slot] = p.owner_peer
		_human_slots.append(p.slot)
		if p.owner_peer != session.local_peer_id:
			_remote_slots.append(p.slot)
	session.begin_match(owners)
	var history := session.history
	director.auto_step = false
	director.source_factory = func(p: PlayerSlotConfig) -> InputSource:
		if p.input_kind == PlayerSlotConfig.InputKind.CPU:
			return p.create_input_source()
		return NetworkInput.new(history, p.slot)
	if hub != null:
		hub.auto_confirm = false
		hub.bind_director(director)
	director.setup(config)
	for slot: int in _local:
		(_local[slot] as InputSource).reset()
		# Ticks 1..delay have no sampled input yet: neutral.
		for t in range(1, input_delay + 1):
			session.submit_local_input(slot, t, InputFrame.new())
	_snapshots[0] = director.save_state()
	session.mispredicted.connect(_on_mispredicted)
	session.command_received.connect(_on_command)
	session.hash_received.connect(_on_hash)
	session.resync_received.connect(_on_resync)
	session.peer_left.connect(_on_peer_left)
	session.session_ended.connect(func(r: int) -> void:
		_abort(&"desync" if r == Protocol.Reason.DESYNC else &"host_left"))


func _physics_process(_delta: float) -> void:
	if auto_run and director != null:
		advance()


## The match scene is going away: this machine stops trading inputs for it
## (Session.end_match), so the next match starts with clean acks.
func _exit_tree() -> void:
	if session != null:
		session.end_match()


## One rendered frame: up to `ticks` sim steps (catch-up after a hitch is
## capped at Tuning.net.max_catchup_ticks).
func advance(ticks: int = 1) -> void:
	if is_aborted:
		return
	_frame += 1
	session.local_tick = director.tick
	session.receive()
	if is_aborted:
		return
	_apply_rollback()
	var stalled := true
	for i in mini(ticks, Tuning.net.max_catchup_ticks):
		if not _can_advance():
			break
		_step_local()
		stalled = false
	if stalled:
		stall_frames += 1
		stalled_for += 1
	else:
		stalled_for = 0
	_advance_confirmed()
	session.local_tick = director.tick
	session.send_pending()


## Host: log a sim command for everyone. It runs at tick >= the host's
## current tick + input delay + 1 (so guests rarely have passed it), or at
## `cmd.tick` when that is later. Returns the tick it was scheduled for.
func issue_command(cmd: Dictionary) -> int:
	var c := cmd.duplicate()
	c["tick"] = maxi(int(c.get("tick", 0)), director.tick + input_delay + 1)
	_log_command(c)
	session.send_command(c)
	return c["tick"]


## The remote slots whose input this peer still waits on (a cut slot only
## until its frames before the cut have arrived).
func waiting_slots() -> Array[int]:
	var out: Array[int] = []
	for slot in _remote_slots:
		if not _slot_done(slot):
			out.append(slot)
	return out


## Cut by a command and every frame before the cut confirmed.
func _slot_done(slot: int) -> bool:
	return _cut.has(slot) and session.history.last_confirmed_tick(slot) >= int(_cut[slot]) - 1


## Name of the peer the sim is stalled on ("" when not stalled).
func waiting_for() -> String:
	if stalled_for < Tuning.net.stall_warning_frames:
		return ""
	var oldest := InputHistory.NO_LIMIT
	var who := ""
	for slot in waiting_slots():
		var t := session.history.last_confirmed_tick(slot)
		if t < oldest:
			oldest = t
			who = session.peer_name(session.slot_owner(slot))
	return who


# --- steps ----------------------------------------------------------------------

func _can_advance() -> bool:
	var oldest := _min_remote_confirmed()
	if oldest != InputHistory.NO_LIMIT and director.tick + 1 - oldest > Tuning.net.max_rollback_frames:
		return false
	return not session.time_sync.should_wait(_frame)


func _step_local() -> void:
	var t := director.tick + 1 + input_delay
	for slot: int in _local:
		var f := (_local[slot] as InputSource).poll(t)
		var prev: int = _local_prev.get(slot, 0)
		if f.held & InputFrame.Btn.PAUSE != 0 and prev & InputFrame.Btn.PAUSE == 0:
			pause_pressed.emit(slot)
		_local_prev[slot] = f.held
		# PAUSE never reaches the sim: the wire strips it, so the history
		# must too (the sources' edge state is in save_state).
		var sent := InputFrame.new() if local_paused else f.duplicate_frame()
		sent.held &= ~InputFrame.Btn.PAUSE
		sent.pressed &= ~InputFrame.Btn.PAUSE
		sent.released &= ~InputFrame.Btn.PAUSE
		session.submit_local_input(slot, t, sent)
	director.step()
	_snapshots[director.tick] = director.save_state()
	_snapshots.erase(director.tick - Tuning.net.max_rollback_frames - 2)


func _apply_rollback() -> void:
	if _rollback_to < 0:
		return
	var t := _rollback_to
	_rollback_to = -1
	if t > director.tick:
		return
	var snap: Variant = _snapshots.get(t - 1)
	if snap == null:
		push_error("RollbackDriver: no snapshot for tick %d (now %d)" % [t - 1, director.tick])
		return
	_resim_from(t - 1, snap)
	rollbacks += 1


## Load `state` (taken after tick `from`) and re-simulate to the present.
func _resim_from(from: int, state: Dictionary) -> void:
	var now := director.tick
	if hub != null:
		hub.rollback_to(from + 1)
	director.load_state(state)
	_snapshots[from] = state
	director.resimulating = true
	while director.tick < now:
		director.step()
		_snapshots[director.tick] = director.save_state()
		rollback_ticks += 1
	director.resimulating = false


func _min_remote_confirmed() -> int:
	var m := InputHistory.NO_LIMIT
	for slot in waiting_slots():
		m = mini(m, session.history.last_confirmed_tick(slot))
	return m


func _advance_confirmed() -> void:
	var c := director.tick
	for slot in _human_slots:
		if not _slot_done(slot):
			c = mini(c, session.history.last_confirmed_tick(slot))
	if c <= confirmed_tick:
		return
	var interval := Tuning.net.checksum_interval
	for tick in range(confirmed_tick + 1, c + 1):
		if tick % interval == 0 and _snapshots.has(tick):
			_checkpoint(tick)
	confirmed_tick = c
	if hub != null:
		hub.confirm_through(c)
	session.history.prune(c)


func _checkpoint(tick: int) -> void:
	var state: Dictionary = _snapshots[tick]
	var h := StateHash.of_state(state)
	confirmed_hashes[tick] = h
	_checkpoints[tick] = state
	_checkpoints.erase(tick - Tuning.net.checksum_interval * Tuning.net.checkpoints_kept)
	confirmed_hashes.erase(tick - Tuning.net.checksum_interval * Tuning.net.checkpoints_kept)
	if session.is_host():
		_compare_pending()
	else:
		session.send_hash(tick, h)


# --- session events -------------------------------------------------------------

func _on_mispredicted(_slot: int, tick: int) -> void:
	_want_rollback(tick)


func _want_rollback(tick: int) -> void:
	if tick <= director.tick:
		_rollback_to = tick if _rollback_to < 0 else mini(_rollback_to, tick)


func _on_command(cmd: Dictionary) -> void:
	_log_command(cmd)


func _log_command(cmd: Dictionary) -> void:
	if not director.add_command(cmd):
		return
	var kind: int = cmd["kind"]
	if kind == MatchDirector.CommandKind.CPU_TAKEOVER or kind == MatchDirector.CommandKind.FORFEIT:
		# A slot cut earlier (a takeover before its team forfeits) stays cut there.
		for slot in _slots_cut_by(cmd):
			_cut[slot] = mini(int(_cut.get(slot, cmd["tick"])), int(cmd["tick"]))
	elif kind == MatchDirector.CommandKind.RECLAIM:
		_cut.erase(int(cmd["slot"]))
	_want_rollback(int(cmd["tick"]))


func _slots_cut_by(cmd: Dictionary) -> Array[int]:
	var out: Array[int] = []
	if cmd["kind"] == MatchDirector.CommandKind.CPU_TAKEOVER:
		out.append(int(cmd["slot"]))
		return out
	for slot in _human_slots:
		var f := director.fighter_for_slot(slot)
		if f != null and f.team == int(cmd["team"]):
			out.append(slot)
	return out


func _on_hash(peer: int, tick: int, hash_value: int) -> void:
	if not session.is_host():
		return
	_pending_guest_hashes.append([peer, tick, hash_value])
	_compare_pending()


## Host: compare guest hashes with our own once we have confirmed that tick.
func _compare_pending() -> void:
	var keep: Array = []
	for e: Array in _pending_guest_hashes:
		var tick: int = e[1]
		if not confirmed_hashes.has(tick):
			if tick > confirmed_tick:
				keep.append(e)  # not confirmed here yet
			continue  # too old to check
		if confirmed_hashes[tick] != e[2]:
			_host_desync(e[0], tick)
	_pending_guest_hashes = keep


func _host_desync(peer: int, tick: int) -> void:
	desync_detected.emit(peer, tick)
	_write_dump(tick, _checkpoints[tick], peer)
	resyncs += 1
	if resyncs > Tuning.net.max_resyncs_per_match:
		_abort(&"desync")
		session.close(Protocol.Reason.DESYNC)  # guests abort too
		return
	session.send_resync(peer, tick, _checkpoints[tick])


func _on_resync(tick: int, snapshot: Dictionary) -> void:
	if session.is_host():
		return
	if _checkpoints.has(tick):
		_write_dump(tick, _checkpoints[tick], Transport.HOST_PEER)
	resyncs += 1
	if resyncs > Tuning.net.max_resyncs_per_match:
		_abort(&"desync")
		return
	_snapshots.clear()
	_rollback_to = -1
	if tick <= director.tick:
		_resim_from(tick, snapshot)
	else:
		director.load_state(snapshot)  # we were behind the host: jump ahead
		_snapshots[tick] = snapshot
	_checkpoints[tick] = snapshot
	confirmed_hashes[tick] = StateHash.of_state(snapshot)
	resynced.emit(tick)


func _on_peer_left(peer: int, _reason: int, last_tick: int) -> void:
	if not session.is_host():
		return
	var cut := maxi(last_tick + 1, confirmed_tick + 1)
	for cmd in drop_out_commands(peer):
		cmd["tick"] = cut
		_issue_at(cmd)


## Host: issue (at the earliest tick) the commands taking `peer`'s slots out
## of the match: a voluntary forfeit / leave run.
func drop_out(peer: int) -> void:
	for cmd in drop_out_commands(peer):
		issue_command(cmd)


## Host: the commands (without a tick) that take `peer`'s slots out of the
## match, once per peer (SPEC_ONLINE.md §13, §17). Every slot of the peer
## becomes a CPU (co-op: at the ally's level). Versus adds a FORFEIT when the
## humans still playing (other peers, still here, not out) are on fewer than
## two teams: one of the peer's teams other than theirs forfeits and their
## team wins (no human left: the director picks). So a 2v2 partner's drop or
## one of three FFA players leaving only puts a CPU in their place; a 1v1
## drop forfeits as before.
func drop_out_commands(peer: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var slots := session.slots_of(peer)
	if slots.is_empty() or director == null or peer in _out_peers:
		return out
	_out_peers.append(peer)
	var cfg := director.config
	var level := cfg.coop.ally_level if cfg.coop != null else -1
	for slot in slots:
		out.append({"kind": MatchDirector.CommandKind.CPU_TAKEOVER, "slot": slot, "cpu_level": level})
	if director.is_coop():
		return out
	var present := session.peer_ids()
	var human_teams: Array[int] = []
	for p in cfg.players:
		var f := director.fighter_for_slot(p.slot)
		if f != null and p.input_kind != PlayerSlotConfig.InputKind.CPU and p.owner_peer != peer \
				and p.owner_peer in present and not p.owner_peer in _out_peers and not f.team in human_teams:
			human_teams.append(f.team)
	if human_teams.size() >= 2:
		return out
	var winner := human_teams[0] if human_teams.size() == 1 else -1
	for slot in slots:
		var f := director.fighter_for_slot(slot)
		if f != null and f.team != winner:
			out.append({"kind": MatchDirector.CommandKind.FORFEIT, "team": f.team, "winner": winner})
			break
	return out


## Host: a command at an exact tick (may be in our past: we roll back too).
func _issue_at(cmd: Dictionary) -> void:
	_log_command(cmd)
	session.send_command(cmd)


func _abort(reason: StringName) -> void:
	if is_aborted:
		return
	is_aborted = true
	aborted.emit(reason)


# --- desync dumps (§8.3) --------------------------------------------------------

## user://desync/<date>_<tick>_<local peer>.txt: the state at the checkpoint,
## the last desync_dump_input_ticks of input per slot, versions. `peer` = the
## other side of the mismatch (host: the guest; guest: the host).
func _write_dump(tick: int, state: Dictionary, peer: int) -> String:
	DirAccess.make_dir_recursive_absolute(dump_dir)
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "-")
	var path := dump_dir.path_join("%s_%d_%d.txt" % [stamp, tick, session.local_peer_id])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("RollbackDriver: can't write desync dump %s" % path)
		return ""
	f.store_line("# desync dump by peer %d: tick %d, mismatch with peer %d" % [session.local_peer_id, tick, peer])
	f.store_line("# identity %s" % [session.identity])
	f.store_line("# inputs (slot: tick move_x move_y held dodge target_request)")
	var from := maxi(tick - Tuning.net.desync_dump_input_ticks, session.history.first_tick)
	for slot in _human_slots:
		for t in range(from, tick + 1):
			var fr := session.history.confirmed_frame(slot, t)
			if fr != null:
				f.store_line("%d: %d %s" % [slot, t, fr.to_array()])
	f.store_line("# state")
	f.store_string(var_to_str(state))
	return path
