extends Node
## Desync handling (SPEC_ONLINE.md §8, §16 net_desync_test): corrupting one
## guest's sim state makes the host see a checkpoint hash mismatch, write a
## dump and RESYNC the guest, which dumps too, loads the host's snapshot and
## agrees again; past max_resyncs_per_match the match is aborted.
## Run as a scene:  godot --headless res://tests/net_desync_test.tscn

const DUMP_DIR := "user://test_desync_dumps"
## Health taken off the guest's fighter to corrupt its state.
const CORRUPTION := 7.0

var _failures := 0


func _ready() -> void:
	_clear_dumps()
	_test_resync()
	_test_limit_aborts()
	_clear_dumps()
	print("NET DESYNC TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _clear_dumps() -> void:
	var d := DirAccess.open(DUMP_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(DUMP_DIR)


## Host + guest over a loopback network, 1v1, 30 ms; returns [net, host
## driver, guest driver].
func _pair() -> Array:
	for c in get_children():
		c.queue_free()
	var net := LoopbackNetwork.new(5)
	var ht := net.create_host()
	var gt := net.create_client()
	var sessions: Array[Session] = [Session.create_host(ht, "Host"), Session.create_guest(gt, "Guest")]
	net.connect_client(gt, ht)
	for s in sessions:
		s.clock = net.now_ms
	for i in 120:
		net.advance_frame()
		for s in sessions:
			s.update()
	net.latency_ms = 30.0
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.ONLINE)
	cfg.round_time_seconds = 0
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = Transport.HOST_PEER + i
		cfg.players.append(p)
	var out: Array = [net]
	for i in 2:
		var d := MatchDirector.new()
		add_child(d)
		var drv := RollbackDriver.new()
		drv.auto_run = false
		drv.dump_dir = DUMP_DIR
		add_child(drv)
		drv.start(d, sessions[i], MatchConfig.from_dict(cfg.to_dict()), {i: TickInput.new(50 + i)}, 2)
		out.append(drv)
	return out


func _run(pair: Array, frames: int) -> void:
	for i in frames:
		(pair[0] as LoopbackNetwork).advance_frame()
		(pair[1] as RollbackDriver).advance()
		(pair[2] as RollbackDriver).advance()


## Change the guest's live state and its newest snapshot (so a rollback
## can't undo it): a real divergence from the host.
func _corrupt(drv: RollbackDriver) -> void:
	var f := drv.director.fighters[0]
	f.health -= CORRUPTION
	drv._snapshots[drv.director.tick] = drv.director.save_state()


## Checkpoints both peers confirmed after `after`, and whether they agree.
func _agree_after(a: RollbackDriver, b: RollbackDriver, after: int) -> Array:
	var n := 0
	var same := true
	for t: int in a.confirmed_hashes:
		if t > after and b.confirmed_hashes.has(t):
			n += 1
			same = same and a.confirmed_hashes[t] == b.confirmed_hashes[t]
	return [n, same]


func _test_resync() -> void:
	var pair := _pair()
	var host: RollbackDriver = pair[1]
	var guest: RollbackDriver = pair[2]
	var detected := []
	host.desync_detected.connect(func(p: int, t: int) -> void: detected.append([p, t]))
	var resynced := []
	guest.resynced.connect(func(t: int) -> void: resynced.append(t))
	_run(pair, 100)
	var before := _agree_after(host, guest, 0)
	_check(before[0] >= 1 and before[1], "resync: in sync before the corruption")
	_corrupt(guest)
	var corrupted_at := guest.director.tick
	_run(pair, 120)
	_check(detected.size() == 1 and detected[0][0] == 2, "resync: host detected the guest's mismatch %s" % str(detected))
	_check(resynced.size() == 1, "resync: guest applied one RESYNC %s" % str(resynced))
	var after: int = resynced[0] if not resynced.is_empty() else corrupted_at
	_run(pair, 120)
	var agree := _agree_after(host, guest, after)
	_check(agree[0] >= 2 and agree[1], "resync: later checkpoints agree again (%d checked)" % agree[0])
	var dumps := DirAccess.get_files_at(DUMP_DIR) if DirAccess.dir_exists_absolute(DUMP_DIR) else PackedStringArray()
	_check(dumps.size() == 2, "resync: host and guest each wrote a desync dump %s" % str(dumps))
	if dumps.size() > 0:
		var text := FileAccess.get_file_as_string(DUMP_DIR.path_join(dumps[0]))
		_check(text.contains("# inputs") and text.contains("\"fighters\""), "resync: dump has inputs and state")
	_check(not host.is_aborted and not guest.is_aborted, "resync: the match goes on")


func _test_limit_aborts() -> void:
	_clear_dumps()
	var pair := _pair()
	var host: RollbackDriver = pair[1]
	var guest: RollbackDriver = pair[2]
	var reasons := []
	host.aborted.connect(func(r: StringName) -> void: reasons.append(r))
	var guest_reasons := []
	guest.aborted.connect(func(r: StringName) -> void: guest_reasons.append(r))
	_run(pair, 60)
	for i in Tuning.net.max_resyncs_per_match + 1:
		_corrupt(guest)
		_run(pair, 100)
	_check(host.is_aborted and reasons == [&"desync"],
		"limit: host aborts with &\"desync\" after %d resyncs (%d, %s)" % [Tuning.net.max_resyncs_per_match, host.resyncs, str(reasons)])
	_run(pair, 30)
	_check(guest.is_aborted and guest_reasons == [&"desync"], "limit: the guest is told and aborts too %s" % str(guest_reasons))
	var tick := host.director.tick
	_run(pair, 10)
	_check(host.director.tick == tick, "limit: an aborted driver stops stepping")
