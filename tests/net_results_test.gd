extends Node
## Headless online results screen test (SPEC_ONLINE.md §10.6, §13). Run as a
## scene (needs autoloads):
##   godot --headless res://tests/net_results_test.tscn
## A host room (Net) and a guest Session + OnlineRoom over a LoopbackNetwork
## fake a finished online match; the screen's scene changes go to `navigate`
## so the test scene stays loaded.

const TMP_DIR := "user://test_net_results/"
const CONNECT_FRAMES := 300
const PUMP_FRAMES := 30
## Results screens the tests spawn (a script error aborts a test silently).
const EXPECTED_SCREENS := 4

var _fails := 0
var _net: LoopbackNetwork
var _host_t: LoopbackTransport
var _guest_t: LoopbackTransport
var _g: Session
var _groom: OnlineRoom
var _starts := 0
var _results_spawned := 0
var _saved_before: PackedStringArray = []


func _ready() -> void:
	Net.auto_pump = false
	_saved_before = _list_dir(Replay.SAVED_DIR)
	_setup()
	check(_g.state == Session.State.CONNECTED, "guest connected")
	if _g.state == Session.State.CONNECTED:
		await _test_online_buttons_and_rematch()
		await _test_to_lobby()
		await _test_departed_and_save()
	_test_forfeit_lines()
	await _test_offline()
	_cleanup()
	check(_results_spawned == EXPECTED_SCREENS, "every results screen loaded")
	print("NET_RESULTS %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func pump(n: int = PUMP_FRAMES) -> void:
	for i in n:
		_net.advance_frame()
		Net.update()
		if _g.state != Session.State.CLOSED:
			_g.update()


# --- harness ---------------------------------------------------------------------

func _setup() -> void:
	_net = LoopbackNetwork.new(1)
	_host_t = _net.create_host()
	Net.start_host(_host_t)
	# Rematches would change scene through Game.start_match: count them instead.
	Net.room.match_starting.disconnect(Net._on_match_starting)
	Net.room.match_starting.connect(func(_c: MatchConfig) -> void: _starts += 1)
	_guest_t = _net.create_client()
	_g = Session.create_guest(_guest_t, "Guest", {"content_hash": ContentHash.compute()})
	_net.connect_client(_guest_t, _host_t)
	_groom = OnlineRoom.new(_g)
	for i in CONNECT_FRAMES:
		pump(1)
		if _g.state == Session.State.CONNECTED:
			break


## The shared config of the fake match: slot 0 = host "Host", slot 1 = guest.
func _online_config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.ONLINE)
	var names := ["Host", "Guest"]
	var owners := [Net.local_peer(), _g.local_peer_id]
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = owners[i]
		p.display_name = names[i]
		cfg.players.append(p)
	return cfg


## Both rooms: a match just ended (lobby -> match -> results).
func _finish_match(cfg: MatchConfig) -> void:
	for room: OnlineRoom in [Net.room, _groom]:
		room.last_config = cfg
		room._set_phase(OnlineRoom.Phase.MATCH)
		room.match_finished()
	pump()


func _spawn_results(res: Dictionary) -> ResultsScreen:
	Game.last_result = res
	var r := (load(Game.SCENE_RESULTS) as PackedScene).instantiate() as ResultsScreen
	r.navigate = func(_path: String) -> void: pass
	add_child(r)
	_results_spawned += 1
	return r


func _free_results(r: ResultsScreen) -> void:
	r.queue_free()
	await frames(2)


# --- tests -----------------------------------------------------------------------

func _test_online_buttons_and_rematch() -> void:
	var cfg := _online_config()
	_finish_match(cfg)
	check(Net.room.phase == OnlineRoom.Phase.RESULTS and _groom.phase == OnlineRoom.Phase.RESULTS,
			"both rooms in results")
	var r := _spawn_results({"winner_slot": 0, "wins": PackedInt32Array([2, 1]), "config": cfg,
		"replay_path": "", "end_reason": &"ko"})
	await frames(3)
	check(r._headline.text == "HOST WINS!", "online headline uses the display name")
	check(r._rematch_btn != null and r._lobby_btn != null and r._save_btn != null, "online buttons exist")
	check(r._rematch_btn.text == "Rematch (0/2)", "rematch shows the vote count")
	check(not r._lobby_btn.disabled, "host can take the room to the lobby")
	check(r._save_btn.disabled, "save replay disabled without a replay")
	check(get_viewport().gui_get_focus_owner() == r._rematch_btn, "online results focus Rematch")

	r._rematch_btn.pressed.emit()
	check(Net.local_peer() in Net.room.rematch_votes, "host vote recorded")
	check(r._rematch_btn.text == "Cancel Rematch (1/2)", "rematch label after voting")
	check(r._vote_label.text.contains("Waiting for Guest"), "waiting for the guest")
	pump()
	check(Net.local_peer() in _groom.rematch_votes, "guest sees the host's vote")
	_groom.request({"op": OnlineRoom.OP_REMATCH, "on": true})
	pump()
	check(_starts == 1, "both votes start the rematch on the host")
	check(Net.room.phase == OnlineRoom.Phase.MATCH and _groom.phase == OnlineRoom.Phase.MATCH,
			"rematch puts both rooms in the match")
	check(r.went_to.is_empty(), "results screen didn't navigate itself on a rematch")
	await _free_results(r)


func _test_to_lobby() -> void:
	var cfg := _online_config()
	_finish_match(cfg)
	var r := _spawn_results({"winner_slot": 1, "wins": PackedInt32Array([1, 2]), "config": cfg,
		"replay_path": "", "end_reason": &"ko"})
	await frames(3)
	check(r._headline.text == "GUEST WINS!", "guest win headline")
	r._lobby_btn.pressed.emit()
	check(Net.room.phase == OnlineRoom.Phase.LOBBY, "host room back in the lobby")
	check(r.went_to == Game.SCENE_LOBBY, "results screen goes to the lobby")
	pump()
	check(_groom.phase == OnlineRoom.Phase.LOBBY, "guest room follows to the lobby")
	await _free_results(r)


func _test_departed_and_save() -> void:
	var cfg := _online_config()
	_finish_match(cfg)
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var replay_path := TMP_DIR.path_join("match.ghr")
	check(Replay.create(cfg).save(replay_path) == OK, "temp replay written")
	var r := _spawn_results({"winner_slot": 0, "wins": PackedInt32Array([2, 0]), "config": cfg,
		"replay_path": replay_path, "end_reason": &"ko"})
	await frames(3)
	check(not r._rematch_btn.disabled, "rematch enabled while everyone is here")
	_g.close()
	pump()
	check(Net.room.departed.has(_g.local_peer_id), "host saw the guest leave")
	check(r._rematch_btn.disabled, "rematch disabled once a player left")
	check(r._status_label.visible and r._status_label.text.contains("Guest disconnected"),
			"shows '<name> disconnected'")

	check(not r._save_btn.disabled, "save replay enabled with a replay")
	r._save_btn.pressed.emit()
	check(r._save_label.text.begins_with("Saved:"), "save replay reports the path")
	var added := _new_saved_files()
	check(added.size() == 1 and Replay.load_file(Replay.SAVED_DIR.path_join(added[0])) != null,
			"saved copy exists and loads")

	r._unhandled_input(_cancel_event())
	check(Net.room == null and r.went_to == Game.SCENE_MAIN_MENU, "ui_cancel leaves to the main menu")
	await _free_results(r)


func _test_forfeit_lines() -> void:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.ONLINE)
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = i + 1
		p.display_name = ["Ann", "Bob"][i]
		cfg.players.append(p)
	var res := {"winner_slot": 0, "config": cfg, "end_reason": &"forfeit"}
	var lines := ResultsScreen.match_end_lines(res, {})
	check(lines.size() == 1 and lines[0] == "Bob forfeited", "forfeit names the losing team")
	lines = ResultsScreen.match_end_lines(res, {2: "Bob"})
	check(lines.size() == 1 and lines[0] == "Bob disconnected", "a disconnect forfeit says disconnected")
	res["end_reason"] = &"ko"
	check(ResultsScreen.match_end_lines(res, {}).is_empty(), "no lines for a plain KO")


func _test_offline() -> void:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		cfg.players.append(p)
	var r := _spawn_results({"winner_slot": 0, "wins": PackedInt32Array([2, 1]), "config": cfg})
	await frames(3)
	check(r._headline.text == "PLAYER 1 WINS!", "offline headline unchanged")
	check(r._lobby_btn == null and r._rematch_btn.text == "Rematch", "offline buttons unchanged")
	r._on_change_setup()
	check(r.went_to == Game.SCENE_LOBBY and Lobby.pending_mode == MatchConfig.Mode.VERSUS_CPU,
			"Change Setup opens the lobby in the match's mode")
	await _free_results(r)
	Lobby.pending_mode = MatchConfig.Mode.LOCAL_VERSUS


# --- helpers ---------------------------------------------------------------------

func _cancel_event() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = &"ui_cancel"
	e.pressed = true
	return e


func _list_dir(dir: String) -> PackedStringArray:
	return DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()


func _new_saved_files() -> PackedStringArray:
	var out: PackedStringArray = []
	for f in _list_dir(Replay.SAVED_DIR):
		if not f in _saved_before:
			out.append(f)
	return out


func _cleanup() -> void:
	Net.leave()
	Net.auto_pump = true
	_groom = null
	_g = null
	_host_t = null
	_guest_t = null
	_net = null
	Game.last_result = {}
	for f in _new_saved_files():
		DirAccess.remove_absolute(Replay.SAVED_DIR.path_join(f))
	for f in _list_dir(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR.path_join(f))
	if DirAccess.dir_exists_absolute(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR)
