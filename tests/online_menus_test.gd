extends Node
## Headless test of the main menu and the online menus (settings, join
## online) plus UpnpHelper.local_addresses(). Run as a scene (needs autoloads):
##   godot --headless res://tests/online_menus_test.tscn
## Net.settings is swapped for one on a temp file, so user://online.cfg is
## never touched. No real network: the only connect goes to localhost and is
## cancelled at once.

const TEMP_CFG := "user://online_menus_test.cfg"
## Nothing listens here; the attempt is cancelled before it could time out.
const UNUSED_LOCAL_ADDRESS := "127.0.0.1:1"

var _fails := 0
var _real_settings: OnlineSettings


func _ready() -> void:
	_real_settings = Net.settings
	_remove_temp()
	Net.settings = OnlineSettings.load_from(TEMP_CFG)
	await _test_main_menu()
	await _test_pending_message()
	await _test_settings_screen()
	await _test_join_screen()
	_test_local_addresses()
	Net.leave()
	Net.settings = _real_settings
	_remove_temp()
	print("ONLINE_MENUS %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func spawn(path: String) -> Node:
	var n := (load(path) as PackedScene).instantiate()
	add_child(n)
	return n


func action(a: String) -> void:
	var ev := InputEventAction.new()
	ev.action = a
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	ev = ev.duplicate()
	ev.pressed = false
	Input.parse_input_event(ev)
	await frames(1)


func key_tap(code: int) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		Input.parse_input_event(e)
		await frames(2)


func _remove_temp() -> void:
	if FileAccess.file_exists(TEMP_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_CFG))


func _focus_text() -> String:
	var f := get_viewport().gui_get_focus_owner()
	return (f as Button).text if f is Button else ""


# --- Tests -----------------------------------------------------------------------

func _test_main_menu() -> void:
	var m := spawn(Game.SCENE_MAIN_MENU) as Control
	await frames(5)
	var labels: Array = (m.get("_list") as Node).get_children().map(
			func(b: Node) -> String: return (b as Button).text if b is Button else "")
	check(labels == ["Play", "Join online", "Controls", "How to Play", "Settings", "Quit"],
			"main menu entries in order (got %s)" % [labels])
	check(_focus_text() == "Play", "main menu focuses Play")
	await action("ui_up")
	check(_focus_text() == "Quit", "main menu focus wraps to Quit")
	await action("ui_down")
	check(_focus_text() == "Play", "main menu focus wraps back to Play")
	m.call("_on_how_to_play")
	await frames(3)
	check(m.get("_how_to") != null and _focus_text() == "Back", "how-to-play panel opens with focus")
	var online_found := false
	var port_found := false
	for l in (m.get("_how_to") as Node).find_children("*", "Label", true, false):
		var t := (l as Label).text
		online_found = online_found or t == "Online"
		port_found = port_found or (t.contains(str(Tuning.net.default_port)) and t.contains("UPnP"))
	check(online_found and port_found, "how-to-play has an Online section naming the port and UPnP")
	await action("ui_cancel")
	check(m.get("_how_to") == null and get_viewport().gui_get_focus_owner() is Button,
			"how-to-play closes, focus restored")
	var msg := m.get("_message") as Label
	check(msg != null and not msg.visible, "no pending message -> message label hidden")
	m.queue_free()
	await frames(2)


func _test_pending_message() -> void:
	Net.pending_message = "Host left the session"
	var m := spawn(Game.SCENE_MAIN_MENU) as Control
	await frames(3)
	var msg := m.get("_message") as Label
	check(msg != null and msg.visible and msg.text == "Host left the session", "main menu shows Net.pending_message")
	check(Net.pending_message.is_empty(), "main menu clears Net.pending_message")
	m.queue_free()
	await frames(2)
	m = spawn(Game.SCENE_MAIN_MENU) as Control
	await frames(3)
	check(not (m.get("_message") as Label).visible, "message shows only once")
	m.queue_free()
	await frames(2)


func _test_settings_screen() -> void:
	var s := spawn(Game.SCENE_SETTINGS) as SettingsScreen
	await frames(3)
	check(get_viewport().gui_get_focus_owner() == s.name_edit, "settings focuses the name field")
	check(s.port_edit.text.is_empty() and s.port_edit.placeholder_text.contains(str(Tuning.net.default_port)),
			"default port shown as placeholder")
	check(s.delay_sel.current() == SettingsScreen.DELAY_AUTO_LABEL, "input delay starts at Auto")
	check(s.delay_sel.options.size() == Tuning.net.input_delay_max + 2, "input delay options: Auto + 0..max")

	check(s.set_name_text("  Goku  "), "valid name accepted")
	check(not s.set_name_text(""), "empty name rejected")
	check(not s.set_name_text("x".repeat(Tuning.net.name_max_len + 1)), "too long name rejected")
	check(not s.set_name_text("bad\nname"), "control characters rejected")
	check(s.status.text.contains("Invalid"), "invalid name shows on the status line")
	check(Net.settings.player_name == "Goku", "rejected names keep the last valid one")
	# Typing goes through text_changed like a real edit.
	s.name_edit.text = "Vegeta"
	s.name_edit.text_changed.emit(s.name_edit.text)
	check(Net.settings.player_name == "Vegeta" and not s.status.text.contains("Invalid"),
			"typing a valid name stores it and clears the error")

	s.delay_sel.cycle(1)
	check(Net.settings.input_delay == 0, "delay Auto -> 0")
	s.delay_sel.cycle(1)
	s.delay_sel.cycle(1)
	check(Net.settings.input_delay == 2, "delay -> 2")

	check(s.set_port_text("9000"), "port 9000 accepted")
	check(not s.set_port_text("80"), "port below 1024 rejected")
	check(not s.set_port_text("70000"), "port above 65535 rejected")
	check(not s.set_port_text("abc"), "non-numeric port rejected")
	check(Net.settings.port == 9000, "rejected ports keep the last valid one")

	s.overlay_sel.cycle(1)
	check(Net.settings.net_overlay, "net overlay toggled on")

	var disk := OnlineSettings.load_from(TEMP_CFG)
	check(disk.player_name == "Vegeta" and disk.input_delay == 2 and disk.port == 9000 and disk.net_overlay,
			"settings persist to the config file")
	check(_real_settings.path == OnlineSettings.DEFAULT_PATH and Net.settings.path == TEMP_CFG,
			"test writes only the temp config")

	check(s.set_port_text(""), "empty port accepted")
	check(OnlineSettings.load_from(TEMP_CFG).port == OnlineSettings.PORT_DEFAULT, "empty port = default")
	check(s.set_port_text(str(Tuning.net.default_port)) and Net.settings.port == OnlineSettings.PORT_DEFAULT,
			"typing the default port stores PORT_DEFAULT")

	# Pad/keyboard navigation reaches every row and wraps.
	var seen: Array[Control] = []
	for i in 5:
		seen.append(get_viewport().gui_get_focus_owner())
		await action("ui_down")
	check(seen == [s.name_edit, s.delay_sel, s.port_edit, s.overlay_sel, s.back_btn]
			and get_viewport().gui_get_focus_owner() == s.name_edit, "settings rows navigable top to bottom, wrapping")
	s.queue_free()
	await frames(2)

	# A reopened screen shows the stored values.
	s = spawn(Game.SCENE_SETTINGS) as SettingsScreen
	await frames(2)
	check(s.name_edit.text == "Vegeta" and s.delay_sel.current() == "2" and s.overlay_sel.current() == "On",
			"settings screen shows stored values")
	s.queue_free()
	await frames(2)


func _test_join_screen() -> void:
	Net.settings.recent_hosts.clear()
	Net.settings.add_recent_host("192.168.0.20:7777", "Krillin", "2026-10-01")
	Net.settings.add_recent_host("example.org", "Piccolo", "2026-10-02")
	Net.settings.add_recent_host("[::1]:7000", "Yamcha", "2026-10-03")
	Net.settings.save()
	var j := spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(3)
	check(get_viewport().gui_get_focus_owner() == j.address_edit, "join screen focuses the address field")
	var rows := j.recent_rows()
	check(rows.size() == 3, "recent hosts list renders 3 entries")
	check(rows.size() == 3 and rows[0].text.contains("Yamcha") and rows[0].text.contains("[::1]:7000")
			and rows[0].text.contains("2026-10-03") and rows[2].text.contains("Krillin"),
			"rows show name, address and date, most recent first")

	check(not j.connect_to("bad host!"), "bad address does not connect")
	check(j.status.text.begins_with("Invalid address") and not j.connecting and Net.session == null,
			"bad address shows the parse error")
	check(not j.connect_to("1.2.3.4:99999") and j.status.text.contains("port"), "port out of range rejected")
	check(not j.connect_to("") and Net.session == null, "empty address rejected")

	# Navigation: address -> Connect -> rows -> Back.
	await action("ui_down")
	check(get_viewport().gui_get_focus_owner() == j.connect_btn, "down from address goes to Connect")
	await action("ui_down")
	check(get_viewport().gui_get_focus_owner() == rows[0], "then to the first recent host")
	await action("ui_right")
	var x := get_viewport().gui_get_focus_owner()
	check(x is Button and (x as Button).text == "x", "right from a row goes to its delete button")
	await action("ui_left")
	check(get_viewport().gui_get_focus_owner() == rows[0], "left goes back to the row")

	# Delete key on a focused row forgets it.
	await key_tap(KEY_DELETE)
	rows = j.recent_rows()
	check(rows.size() == 2 and not rows[0].text.contains("Yamcha"), "Delete removes the focused host")
	check(get_viewport().gui_get_focus_owner() == rows[0], "focus moves to the next host")
	j.forget("192.168.0.20:7777")
	rows = j.recent_rows()
	check(rows.size() == 1 and rows[0].text.contains("Piccolo"), "forget() removes an entry")
	var disk := OnlineSettings.load_from(TEMP_CFG)
	check(disk.recent_hosts.size() == 1 and disk.recent_hosts[0]["address"] == "example.org",
			"deleting persists")

	# A connect to localhost (nothing listening) is cancelled by Back.
	check(j.connect_to(UNUSED_LOCAL_ADDRESS) and j.connecting and Net.session != null
			and j.status.text.begins_with("Connecting"), "valid address starts connecting")
	check(j.connect_btn.disabled, "Connect disabled while connecting")
	j.back()
	check(not j.connecting and Net.session == null and j.status.text == "Cancelled" and j.is_inside_tree(),
			"Back while connecting cancels and stays")
	Net.join_failed.emit(Protocol.Reason.ROOM_FULL, "Room is full")
	check(j.status.text == "Room is full" and not j.connect_btn.disabled, "join_failed text shows on the status line")
	j.queue_free()
	await frames(2)

	Net.settings.recent_hosts.clear()
	Net.settings.save()
	j = spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(2)
	check(j.recent_rows().is_empty(), "empty recent hosts list renders no rows")
	j.queue_free()
	await frames(2)


func _test_local_addresses() -> void:
	var addrs := UpnpHelper.local_addresses()
	var bad := false
	for a in addrs:
		bad = bad or a.begins_with("127.") or a == "::1" or a == "0:0:0:0:0:0:0:1" \
				or a.begins_with("169.254.") or a.to_lower().begins_with("fe80")
	check(not bad, "local_addresses skips loopback / link-local (%s)" % [addrs])
	check(UpnpHelper._is_v6_loopback("0:0:0:0:0:0:0:1") and UpnpHelper._is_v6_loopback("::1")
			and not UpnpHelper._is_v6_loopback("2001:db8::1"), "IPv6 loopback recognised in any spelling")
	var u := UpnpHelper.new()
	u.stop()
	u.poll()
	check(u.status == UpnpHelper.Status.IDLE, "idle UpnpHelper stop/poll are no-ops")
