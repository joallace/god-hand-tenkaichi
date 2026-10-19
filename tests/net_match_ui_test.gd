extends Node
## Online match presentation (SPEC_ONLINE.md §7.1, §10.3, §10.6, §13): the
## real match scene hosting over a LoopbackNetwork (Net autoload as host, a
## bare guest Session + RollbackDriver + director in-process), stepped by
## hand. Checks the online pause overlay (no tree / director pause, local
## neutral frames, room pause flag, other peers' "⏸ <name>" tag), the
## "Waiting for <name>…" banner on a silent guest, the net overlay toggles
## (setting, pause menu, F3), the disconnect notice, the Forfeit item ending
## the match on both peers, names in the HUD, and that offline pause is
## unchanged.
##   godot --headless res://tests/net_match_ui_test.tscn

const SETTINGS_PATH := "user://net_match_ui_test.cfg"
const INPUT_DELAY := 2
const HOST_NAME := "Hosty"
const GUEST_NAME := "Guest"
## Frames to wait for a forfeit to reach the confirmed match end.
const FORFEIT_FRAMES := 180

var _failures := 0
var _net: LoopbackNetwork
var _guest: Session
var _guest_driver: RollbackDriver
var _guest_director: MatchDirector
var _match: MatchScene


func _ready() -> void:
	var saved_path := Net.settings.path
	var saved_overlay := Net.settings.net_overlay
	var saved_delay := Net.settings.input_delay
	var saved_name := Net.settings.player_name
	Net.settings.path = SETTINGS_PATH
	Net.settings.net_overlay = false
	Net.settings.input_delay = INPUT_DELAY
	Net.settings.player_name = HOST_NAME
	Net.auto_pump = false

	if _check(_connect(), "guest connects over loopback"):
		_test_online()
	_free_match()
	Net.leave()
	_test_offline_pause()

	Net.auto_pump = true
	Net.settings.path = saved_path
	Net.settings.net_overlay = saved_overlay
	Net.settings.input_delay = saved_delay
	Net.settings.player_name = saved_name
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	Game.current_config = null
	print("NET MATCH UI TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


# --- harness ------------------------------------------------------------------

func _connect() -> bool:
	_net = LoopbackNetwork.new(3)
	Net.start_host(_net.create_host())
	var gt := _net.create_client()
	_guest = Session.create_guest(gt, GUEST_NAME, {"content_hash": ContentHash.compute()})
	_net.connect_client(gt, Net.transport as LoopbackTransport)
	Net.session.clock = _net.now_ms
	_guest.clock = _net.now_ms
	for i in 300:
		_net.advance_frame()
		Net.update()
		_guest.update()
		if _guest.state == Session.State.CONNECTED:
			return true
	return false


## Shared versus config: slot 0 = host (keyboard), slot 1 = guest.
static func _config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.ONLINE)
	cfg.rng_seed = 5
	var names := [HOST_NAME, GUEST_NAME]
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = Transport.HOST_PEER + i
		p.display_name = names[i]
		p.device_kind = Bindings.Kind.KEYBOARD
		p.device_id = -1
		cfg.players.append(p)
	return cfg


func _frames(n: int, guest_runs: bool = true) -> void:
	for i in n:
		_net.advance_frame()
		_match.driver.advance()
		if guest_runs:
			_guest_driver.advance()


func _free_match() -> void:
	if _match != null:
		remove_child(_match)
		_match.free()
		_match = null
	for n: Node in [_guest_driver, _guest_director]:
		if n != null:
			n.free()
	_guest_driver = null
	_guest_director = null


# --- online -----------------------------------------------------------------------

func _test_online() -> void:
	var cfg := _config()
	Net.room.phase = OnlineRoom.Phase.MATCH  # as after MATCH_START
	Game.current_config = MatchConfig.from_dict(cfg.to_dict())
	_match = (load(Game.SCENE_MATCH) as PackedScene).instantiate()
	add_child(_match)
	if not _check(_match.driver != null and _match.is_online_match(), "online match scene runs a RollbackDriver"):
		return
	_match.driver.auto_run = false
	_check(_match.driver.input_delay == INPUT_DELAY, "input delay from settings")

	_guest_director = MatchDirector.new()
	add_child(_guest_director)
	_guest_driver = RollbackDriver.new()
	_guest_driver.auto_run = false
	add_child(_guest_driver)
	_guest_driver.start(_guest_director, _guest, MatchConfig.from_dict(cfg.to_dict()),
		{1: InputSource.new()}, INPUT_DELAY)
	_frames(30)

	var d := _match.director
	var hud := _match.hud
	var menu := _match.pause_menu
	_check(d.tick > 0, "host sim advances (tick %d)" % d.tick)
	_check((hud.panels[0]["name"] as Label).text.contains(HOST_NAME)
		and (hud.panels[1]["name"] as Label).text.contains(GUEST_NAME), "HUD names are display names")
	_check(menu.find_children("RestartRun", "Button", true, false).is_empty()
		and menu.find_children("Forfeit", "Button", true, false).size() == 1
		and menu.find_children("NetStats", "Button", true, false).size() == 1, "online pause items (Forfeit, Net Stats)")

	# director.pause_requested is ignored online; the driver's PAUSE edge opens.
	d.pause_requested.emit(0)
	_check(not menu.is_open, "director pause_requested ignored online")
	_match.driver.pause_pressed.emit(0)
	var t0 := d.tick
	_frames(10)
	_check(menu.is_open and menu.visible, "pause_pressed opens the overlay")
	_check(not get_tree().paused and not d.paused and d.tick > t0, "online pause keeps the sim running")
	_check(_match.driver.local_paused, "local slots send neutral frames while open")
	_check(Transport.HOST_PEER in Net.room.paused_peers, "room knows this peer paused")
	_check(not (hud.panels[0]["pause_tag"] as Label).visible, "no pause tag for my own pause")
	_match.driver.pause_pressed.emit(0)
	_check(not menu.is_open and not _match.driver.local_paused
		and not Transport.HOST_PEER in Net.room.paused_peers, "second press closes and clears")

	# The guest pauses: its tag shows on its panel.
	_guest.send_lobby_request({"op": OnlineRoom.OP_PAUSE, "on": true})
	_frames(10)
	var tag: Label = hud.panels[1]["pause_tag"]
	_check(tag.visible and tag.text == Tuning.hud.text_pause_tag % GUEST_NAME, "guest pause tag: '%s'" % tag.text)
	_guest.send_lobby_request({"op": OnlineRoom.OP_PAUSE, "on": false})
	_frames(10)
	_check(not tag.visible, "guest pause tag clears")

	# Net overlay: setting off -> hidden; Net Stats item and F3 toggle it.
	var ov := _match.net_overlay
	ov.refresh()
	_check(ov != null and not ov.visible, "net overlay hidden by default setting")
	_match.driver.pause_pressed.emit(0)
	(menu.find_children("NetStats", "Button", true, false)[0] as Button).pressed.emit()
	ov.refresh()
	_check(Net.settings.net_overlay and ov.visible and ov.label.text.contains("rollbacks")
		and ov.label.text.contains(GUEST_NAME), "Net Stats shows the overlay")
	_match.driver.pause_pressed.emit(0)
	var f3 := InputEventKey.new()
	f3.keycode = KEY_F3
	f3.pressed = true
	ov._input(f3)
	_check(not Net.settings.net_overlay and not ov.visible, "F3 hides it")
	var reloaded := OnlineSettings.load_from(SETTINGS_PATH)
	_check(not reloaded.net_overlay, "overlay setting saved")

	# A silent guest stalls the host: the waiting banner names it.
	_frames(Tuning.net.max_rollback_frames + Tuning.net.stall_warning_frames + 10, false)
	_match.refresh_net_ui()
	_check(hud.waiting_label.visible and hud.waiting_label.text == Tuning.hud.text_waiting_for % GUEST_NAME,
		"waiting banner: '%s'" % hud.waiting_label.text)
	_frames(90)
	_match.refresh_net_ui()
	_check(not hud.waiting_label.visible, "banner hides once the guest is back")

	Net.room.peer_departed.emit(2, GUEST_NAME)
	_check(hud.notice_label.text == Tuning.hud.text_disconnected % GUEST_NAME, "disconnect notice")

	# Forfeit from the overlay ends the match on both peers.
	_match.driver.pause_pressed.emit(0)
	(menu.find_children("Forfeit", "Button", true, false)[0] as Button).pressed.emit()
	_check(not menu.is_open and not _match.driver.local_paused, "Forfeit closes the overlay")
	for i in FORFEIT_FRAMES:
		_frames(1)
		if d.end_reason == &"forfeit" and _guest_director.end_reason == &"forfeit":
			break
	_check(d.end_reason == &"forfeit" and _guest_director.end_reason == &"forfeit", "forfeit ends the match on both peers")
	_check(_match.is_ending(), "confirmed match end reached the scene")


# --- offline ----------------------------------------------------------------------

func _test_offline_pause() -> void:
	var cfg := MatchConfig.from_defaults()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.device_kind = Bindings.Kind.KEYBOARD
		cfg.players.append(p)
	Game.current_config = cfg
	_match = (load(Game.SCENE_MATCH) as PackedScene).instantiate()
	add_child(_match)
	_check(_match.driver == null and _match.net_overlay == null, "offline: no driver, no net overlay")
	var menu := _match.pause_menu
	_check(menu.find_children("NetStats", "Button", true, false).is_empty()
		and menu.find_children("Forfeit", "Button", true, false).is_empty(), "offline pause items unchanged")
	_match.director.pause_requested.emit(0)
	_check(menu.is_open and _match.director.paused and get_tree().paused, "offline pause pauses tree + director")
	menu.resume()
	_check(not _match.director.paused and not get_tree().paused, "offline resume")
	_free_match()
