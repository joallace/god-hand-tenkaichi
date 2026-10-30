extends Node
## Headless test of the room-code (WebRTC) plumbing Net and the menus own,
## without real WebRTC: join text parsing, signaling URL resolution, invite
## links, the signaling_url setting, Net's backend gating, a stand-in room
## transport (room_opened / signaling_error / signaling_lost /
## last_error_text) driving Net and the lobby's room bar, the join screen's
## pending code, and the background-tab warning.
##   godot --headless res://tests/room_codes_test.tscn
## PlatformCaps.web / webrtc and Net.settings are restored afterwards.

const TEMP_CFG := "user://room_codes_test.cfg"
const CODE := "K7QX2M"
const DESKTOP_URL := "ws://127.0.0.1:8765"
const PATH := "/signal"


## Room-code transport stand-in: the signals and error text of
## WebRtcTransport, no network.
class FakeRoomTransport:
	extends Transport
	signal room_opened(code: String)
	signal signaling_error(code: String, text: String)
	signal signaling_lost()
	var host := true
	var error_text := ""
	var events: Array[Dictionary] = []

	func is_host() -> bool:
		return host

	func poll() -> Array[Dictionary]:
		var out := events
		events = []
		return out

	## As WebRtcTransport: a failed join is DISCONNECTED for HOST_PEER with
	## the reason in last_error_text().
	func fail_join(text: String) -> void:
		error_text = text
		events.append(make_event(EventType.DISCONNECTED, HOST_PEER))

	func last_error_text() -> String:
		return error_text


var _fails := 0
var _real_web := false
var _real_webrtc := false
var _real_settings: OnlineSettings


func _ready() -> void:
	_real_web = PlatformCaps.web
	_real_webrtc = PlatformCaps.webrtc
	_real_settings = Net.settings
	_remove_temp()
	Net.settings = OnlineSettings.load_from(TEMP_CFG)
	Net.auto_pump = false
	_test_codes()
	_test_parse_join_text()
	_test_signaling_url()
	_test_links()
	_test_settings()
	_test_caps()
	_test_join_gating()
	_test_room_host()
	_test_guest_failure()
	await _test_lobby()
	await _test_join_screen()
	await _test_background_warning()
	Net.leave()
	Net.auto_pump = true
	PlatformCaps.web = _real_web
	PlatformCaps.webrtc = _real_webrtc
	Net.settings = _real_settings
	_remove_temp()
	print("ROOM_CODES %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
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


## A pad plugged into the machine must not drive the screens under test.
func _input(_event: InputEvent) -> void:
	get_viewport().set_input_as_handled()


func _remove_temp() -> void:
	if FileAccess.file_exists(TEMP_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_CFG))


func _set_caps(web: bool, webrtc: bool) -> void:
	PlatformCaps.web = web
	PlatformCaps.webrtc = webrtc


# --- pure helpers -----------------------------------------------------------------

func _test_codes() -> void:
	check(Net.normalize_room_code(" k7q-x2m ") == CODE and Net.normalize_room_code("k7q x2m") == CODE
			and Net.normalize_room_code("K7Q_X2M") == CODE, "codes: case, spaces, dashes, underscores normalized")
	check(Net.is_room_code(CODE) and Net.is_room_code("ABCDEF") and Net.is_room_code("234567"),
			"codes: six chars of the alphabet")
	check(not Net.is_room_code("K7QX2") and not Net.is_room_code("K7QX2MM") and not Net.is_room_code("K7QX2O")
			and not Net.is_room_code("K7QX21") and not Net.is_room_code("K7QX2I") and not Net.is_room_code("k7qx2m"),
			"codes: wrong length, 0/O/1/I and lower case (unnormalized) refused")


func _test_parse_join_text() -> void:
	var p := Net.parse_join_text("  k7q-x2m ")
	check(p["kind"] == "code" and p["code"] == CODE and p["signal"] == "", "join text: a code")
	p = Net.parse_join_text("https://example.org/game/?room=k7qx2m")
	check(p["kind"] == "code" and p["code"] == CODE, "join text: an invite URL")
	p = Net.parse_join_text("https://example.org/?signal=wss%3A%2F%2Fsig.example.org%3A9000&room=K7QX2M#x")
	check(p["kind"] == "code" and p["code"] == CODE and p["signal"] == "wss://sig.example.org:9000",
			"join text: an invite URL keeps its signal param")
	p = Net.parse_join_text("https://example.org/?room=K7QX2M&signal=http://nope")
	check(p["kind"] == "code" and p["signal"] == "", "join text: a non-ws signal param is ignored")
	p = Net.parse_join_text("room=K7QX2M")
	check(p["kind"] == "code" and p["code"] == CODE, "join text: a bare room= query")
	p = Net.parse_join_text("https://example.org/?room=OOPS00")
	check(p["kind"] == "invalid" and not str(p["error"]).is_empty(), "join text: an invite with a bad code is invalid")
	p = Net.parse_join_text("192.168.0.20:7777")
	check(p["kind"] == "address" and p["address"] == "192.168.0.20:7777", "join text: IP:PORT is an address")
	p = Net.parse_join_text(" example.org ")
	check(p["kind"] == "address" and p["address"] == "example.org", "join text: a hostname is an address")
	p = Net.parse_join_text("[::1]:7000")
	check(p["kind"] == "address", "join text: [IPv6]:PORT is an address")
	p = Net.parse_join_text("ABCDEF:7777")
	check(p["kind"] == "address", "join text: a code-like host with a port is an address")
	p = Net.parse_join_text("bad host!")
	check(p["kind"] == "invalid" and not str(p["error"]).is_empty(), "join text: junk is invalid with a reason")
	p = Net.parse_join_text("   ")
	check(p["kind"] == "invalid", "join text: empty is invalid")


func _test_signaling_url() -> void:
	var https := {"protocol": "https:", "host": "play.example.org", "hostname": "play.example.org", "search": ""}
	var lan := {"protocol": "https:", "host": "192.168.0.10:8443", "hostname": "192.168.0.10", "search": ""}
	var http := {"protocol": "http:", "host": "localhost:8000", "hostname": "localhost", "search": "?x=1"}
	check(Net.resolve_signaling_url("", false, {}, DESKTOP_URL, "", PATH) == DESKTOP_URL,
			"signaling: desktop default is the tuning URL")
	check(Net.resolve_signaling_url("  wss://mine.example:1 ", false, {}, DESKTOP_URL, "", PATH) == "wss://mine.example:1",
			"signaling: the settings override wins on desktop")
	check(Net.resolve_signaling_url("ws://mine:1", true, https, DESKTOP_URL, "", PATH) == "ws://mine:1",
			"signaling: the settings override wins on web")
	check(Net.resolve_signaling_url("", true, https, DESKTOP_URL, "", PATH) == "wss://play.example.org/signal",
			"signaling: https page -> wss on the page's origin + path")
	check(Net.resolve_signaling_url("", true, lan, DESKTOP_URL, "", PATH) == "wss://192.168.0.10:8443/signal",
			"signaling: the page's port is kept (serve_web.py on the LAN: one certificate)")
	check(Net.resolve_signaling_url("", true, http, DESKTOP_URL, "", "signal") == "ws://localhost:8000/signal",
			"signaling: http page -> ws; a path without '/' gets one")
	check(Net.resolve_signaling_url("", true, https, DESKTOP_URL, "wss://sig.example.org", PATH) == "wss://sig.example.org",
			"signaling: a tuning web URL beats the page origin")
	var with_signal := {"protocol": "https:", "host": "h", "search": "?signal=ws%3A%2F%2F10.0.0.2%3A9000&room=X"}
	check(Net.resolve_signaling_url("", true, with_signal, DESKTOP_URL, "wss://sig.example.org", PATH) == "ws://10.0.0.2:9000",
			"signaling: ?signal= overrides the page origin and the tuning web URL")
	var bad_signal := {"protocol": "http:", "host": "h", "search": "?signal=javascript:alert(1)"}
	check(Net.resolve_signaling_url("", true, bad_signal, DESKTOP_URL, "", PATH) == "ws://h/signal",
			"signaling: an invalid ?signal= is ignored")
	var v6 := {"protocol": "http:", "hostname": "::1", "search": ""}
	check(Net.resolve_signaling_url("", true, v6, DESKTOP_URL, "", PATH) == "ws://[::1]/signal",
			"signaling: a bare IPv6 hostname (no host key) is bracketed")
	check(Net.resolve_signaling_url("", true, {}, DESKTOP_URL, "", PATH) == DESKTOP_URL,
			"signaling: web without a readable location falls back to the desktop URL")
	check(Net.desktop_signaling_url() == DESKTOP_URL and Tuning.net.signaling_path == PATH
			and Tuning.net.web_signaling_url == "", "signaling: tuning defaults")
	var hint := Net.with_server_hint(SignalingClient.TEXT_UNREACHABLE, "ws://127.0.0.1:8765")
	check(hint.contains("ws://127.0.0.1:8765") and hint.contains("Settings > Online"),
			"signaling: an unreachable server's text names the URL and the setting (%s)" % hint)
	check(Net.with_server_hint("No room with that code", "ws://x") == "No room with that code",
			"signaling: other errors are left as they are")



func _test_links() -> void:
	check(Net.invite_url("https://play.example.org/game/index.html", CODE)
			== "https://play.example.org/game/index.html?room=%s" % CODE, "invite: page URL + ?room=")
	check(Net.invite_url("https://play.example.org/?room=OLD234&foo=1#top", CODE)
			== "https://play.example.org/?room=%s" % CODE, "invite: old query and fragment dropped")
	check(Net.invite_url("http://localhost:8000/?signal=ws%3A%2F%2F10.0.0.2%3A9000", CODE)
			== "http://localhost:8000/?room=%s&signal=%s" % [CODE, "ws://10.0.0.2:9000".uri_encode()],
			"invite: the page's signal param is kept")
	check(Net.invite_url("https://h/?signal=ws%3A%2F%2Fold%3A1", CODE, "wss://mine:2")
			== "https://h/?room=%s&signal=%s" % [CODE, "wss://mine:2".uri_encode()],
			"invite: the server in use (a Settings override) wins over the page's")
	var round := Net.parse_join_text(Net.invite_url("http://h/?signal=ws%3A%2F%2Fs%3A1", CODE))
	check(round["kind"] == "code" and round["code"] == CODE and round["signal"] == "ws://s:1",
			"invite: an invite URL parses back to its code and signal")
	check(Net.strip_query_param("https://h/p?room=K7QX2M", "room") == "https://h/p",
			"strip: the only param leaves no '?'")
	check(Net.strip_query_param("https://h/p?signal=a&room=K7QX2M&x=1#f", "room") == "https://h/p?signal=a&x=1#f",
			"strip: other params and the fragment kept")
	check(Net.strip_query_param("https://h/p", "room") == "https://h/p", "strip: no query, unchanged")
	check(Net.room_code_from_query("?room=k7qx2m") == CODE and Net.room_code_from_query("?room=nope") == ""
			and Net.room_code_from_query("") == "", "boot: room code from the page query")
	check(Net.parse_query("?a=1&b=x%20y&a=2&c&d=e+f") == {"a": "1", "b": "x y", "c": "", "d": "e f"},
			"query: decoding, first key wins, bare keys, '+'")


func _test_settings() -> void:
	var s := OnlineSettings.load_from(TEMP_CFG)
	check(s.signaling_url == "", "settings: signaling_url defaults to empty")
	check(s.set_signaling_url(" wss://sig.example.org:9000 ") and s.signaling_url == "wss://sig.example.org:9000",
			"settings: a wss URL is stored stripped")
	check(not s.set_signaling_url("http://x") and not s.set_signaling_url("ws://") and not s.set_signaling_url("ws:// a")
			and s.signaling_url == "wss://sig.example.org:9000", "settings: invalid URLs refused, last valid kept")
	check(s.save() == OK, "settings: save")
	var disk := OnlineSettings.load_from(TEMP_CFG)
	check(disk.signaling_url == "wss://sig.example.org:9000", "settings: signaling_url round-trips online.cfg")
	check(disk.set_signaling_url("") and disk.signaling_url == "", "settings: empty = default")
	var cf := ConfigFile.new()
	cf.load(TEMP_CFG)
	cf.set_value("online", "signaling_url", "ftp://junk")
	cf.save(TEMP_CFG)
	check(OnlineSettings.load_from(TEMP_CFG).signaling_url == "", "settings: a junk URL on disk loads as default")
	_remove_temp()


func _test_caps() -> void:
	_set_caps(false, false)
	check(PlatformCaps.direct_ip() and not PlatformCaps.room_codes() and PlatformCaps.online()
			and PlatformCaps.net_backend() == PlatformCaps.NetBackend.ENET, "caps: desktop without room codes")
	_set_caps(false, true)
	check(PlatformCaps.direct_ip() and PlatformCaps.room_codes() and PlatformCaps.online()
			and PlatformCaps.net_backend() == PlatformCaps.NetBackend.WEBRTC, "caps: desktop with room codes prefers them")
	_set_caps(true, true)
	check(not PlatformCaps.direct_ip() and PlatformCaps.room_codes() and PlatformCaps.online()
			and PlatformCaps.net_backend() == PlatformCaps.NetBackend.WEBRTC, "caps: web with room codes")
	_set_caps(true, false)
	check(not PlatformCaps.online() and PlatformCaps.net_backend() == PlatformCaps.NetBackend.NONE,
			"caps: web without room codes has no online")
	_set_caps(_real_web, _real_webrtc)


func _test_join_gating() -> void:
	_set_caps(true, true)
	check(Net.join("127.0.0.1:1") == ERR_INVALID_PARAMETER and Net.session == null,
			"web: an address is refused (ERR_INVALID_PARAMETER)")
	check(Net.join("not a code!") == ERR_INVALID_PARAMETER and Net.session == null, "web: junk refused")
	check(Net.host() == ERR_UNAVAILABLE and Net.session == null, "web: no direct-IP hosting")
	var err := Net.join(CODE.to_lower())
	# Stub transport: refused; the real one starts a room-code join.
	check(err != OK or (Net.backend == PlatformCaps.NetBackend.WEBRTC and Net.join_code == CODE
			and Net.join_address == ""), "web: a code goes to the room-code backend (err %d)" % err)
	Net.leave()
	_set_caps(false, false)
	check(Net.join(CODE) == ERR_UNAVAILABLE and Net.session == null, "desktop without room codes: a code is unavailable")
	check(Net.host_room() == ERR_UNAVAILABLE and Net.session == null, "desktop without room codes: no host_room")
	check(Net.join("bad host!") == ERR_INVALID_PARAMETER, "desktop: junk refused")
	# No signaling server known (a release build without signaling_url).
	_set_caps(false, true)
	var real_url := Tuning.net.signaling_url
	var real_dev := Tuning.net.dev_signaling_url
	Tuning.net.signaling_url = ""
	Tuning.net.dev_signaling_url = ""
	check(not Net.room_codes_ready() and not Lobby.two_room_kinds(),
			"no signaling server: room codes not ready, direct IP stays the room default")
	check(Net.host_room() == ERR_UNCONFIGURED and Net.session == null, "no signaling server: host_room unconfigured")
	check(Net.join(CODE) == ERR_UNCONFIGURED and Net.session == null, "no signaling server: a code join unconfigured")
	Net.settings.signaling_url = "ws://127.0.0.1:1"
	check(Net.room_codes_ready() and Lobby.two_room_kinds(), "a Settings server makes room codes ready")
	Net.settings.signaling_url = ""
	Tuning.net.signaling_url = real_url
	Tuning.net.dev_signaling_url = real_dev
	check(Net.room_codes_ready(), "debug build: the dev server is the fallback")
	_set_caps(true, false)
	check(Net.join(CODE) == ERR_UNAVAILABLE and Net.host_room() == ERR_UNAVAILABLE,
			"web without room codes: everything unavailable")
	_set_caps(_real_web, _real_webrtc)
	var id := Net.game_id()
	check(id == "%d:%s" % [Protocol.PROTOCOL_VERSION, ContentHash.compute()], "game id: protocol version + content hash")


## Start a room-code host on a stand-in transport, as host_room() would.
func _fake_host() -> FakeRoomTransport:
	var t := FakeRoomTransport.new()
	Net.start_host(t)
	Net.backend = PlatformCaps.NetBackend.WEBRTC
	Net.watch_signaling(t)
	return t


func _test_room_host() -> void:
	var t := _fake_host()
	var codes: Array[String] = []
	var problems: Array[String] = []
	var on_code := func(c: String) -> void: codes.append(c)
	var on_problem := func(p: String) -> void: problems.append(p)
	Net.room_code_changed.connect(on_code)
	Net.signaling_problem.connect(on_problem)
	check(Net.is_host() and Net.room_code == "" and Net.invite_text() == "", "room host: no code yet")
	t.room_opened.emit(CODE)
	check(Net.room_code == CODE and codes == [CODE], "room host: room_opened -> Net.room_code + room_code_changed")
	check(Net.invite_text() == CODE, "room host: off the web the invite is the bare code")
	t.signaling_error.emit("rate_limited", "Too many requests")
	check(Net.signaling_error_text == "Too many requests" and problems == ["Too many requests"],
			"room host: signaling_error -> signaling_error_text")
	t.signaling_lost.emit()
	check(Net.room_code == "" and codes == [CODE, ""] and Net.signaling_error_text == Net.SIGNALING_LOST_TEXT
			and Net.is_online(), "room host: signaling_lost drops the code, keeps the room")
	Net.room_code_changed.disconnect(on_code)
	Net.signaling_problem.disconnect(on_problem)
	Net.leave()
	check(Net.backend == PlatformCaps.NetBackend.NONE and Net.room_code == "" and Net.signaling_error_text == "",
			"leave() clears the room-code state")


func _test_guest_failure() -> void:
	var t := FakeRoomTransport.new()
	t.host = false
	Net.start_guest(t)
	Net.backend = PlatformCaps.NetBackend.WEBRTC
	Net.join_code = CODE
	var fails: Array[String] = []
	var on_fail := func(_r: int, text: String) -> void: fails.append(text)
	Net.join_failed.connect(on_fail)
	Net.update()
	check(fails.is_empty() and Net.session != null, "room guest: still joining while the transport has no error")
	t.fail_join("Room not found")
	Net.update()
	check(fails == ["Room not found"] and Net.session == null, "room guest: the transport's error fails the join at once")
	Net.join_failed.disconnect(on_fail)
	# The session-end path uses the same text (and the generic one without).
	t = FakeRoomTransport.new()
	t.host = false
	Net.start_guest(t)
	t.error_text = "Could not reach the host (a TURN relay may be needed)"
	check(Net.connect_failed_text() == t.error_text, "connect failure text: the transport's reason")
	Net.leave()
	Net.start_guest(LoopbackNetwork.new(1).create_client())
	check(Net.connect_failed_text() == Net.CONNECT_FAILED_TEXT, "connect failure text: generic without one")
	Net.leave()


func _room_text(l: Lobby) -> String:
	return (l.get("_room_label") as Label).text


func _test_lobby() -> void:
	# Desktop with room codes, local: two ways to open a room.
	_set_caps(false, true)
	var l := spawn(Game.SCENE_LOBBY) as Lobby
	await frames(2)
	var room_btn := l.get("_room_button") as Button
	var direct_btn := l.get("_direct_button") as Button
	check(room_btn.visible and room_btn.text == "Room code" and direct_btn.visible,
			"desktop+codes lobby: Room code and Direct IP buttons")
	var hint_ok := false
	for lab in l.find_children("*", "Label", true, false):
		hint_ok = hint_ok or ((lab as Label).text.contains("TAB room") and (lab as Label).text.contains("C by IP"))
	check(hint_ok, "desktop+codes lobby: hint names TAB room and C by IP")
	l.queue_free()
	await frames(2)
	_set_caps(false, false)
	l = spawn(Game.SCENE_LOBBY) as Lobby
	await frames(2)
	check((l.get("_room_button") as Button).text == "Open online" and not (l.get("_direct_button") as Button).visible,
			"desktop lobby without codes: one Open online button")
	l.queue_free()
	await frames(2)

	# Hosting by code (stand-in transport), seen on web.
	_set_caps(true, true)
	var t := _fake_host()
	l = spawn(Game.SCENE_LOBBY) as Lobby
	l.auto_start = false
	await frames(2)
	var copy_btn := l.get("_copy_button") as Button
	check(_room_text(l).contains("Hosting") and _room_text(l).contains("Opening room") and not copy_btn.visible,
			"code host lobby: Opening room…, nothing to copy yet")
	t.room_opened.emit(CODE)
	await frames(1)
	check(_room_text(l).contains("Room code: %s" % CODE) and copy_btn.visible, "code host lobby: shows the code")
	check(not _room_text(l).contains("UPnP") and not _room_text(l).contains("UDP")
			and not (l.get("_direct_button") as Button).visible, "code host lobby: no LAN / UPnP / port text")
	l.copy_address()
	check(_room_text(l).contains("Copied"), "code host lobby: copy action")
	t.signaling_error.emit("server_full", "The room server is full")
	await frames(1)
	check(_room_text(l).contains("The room server is full"), "code host lobby: shows a signaling error")
	l.close_room()
	check(not Net.is_online() and not l.is_online(), "code host lobby: Close room")
	l.queue_free()
	await frames(2)
	_set_caps(_real_web, _real_webrtc)


func _test_join_screen() -> void:
	# Web: the code field only.
	_set_caps(true, true)
	Net.settings.add_recent_host("192.168.0.20:7777", "Krillin", "2026-10-01")
	var j := spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(3)
	check(j.code_edit.is_visible_in_tree() and not j.address_edit.is_visible_in_tree() and j.recent_rows().is_empty()
			and get_viewport().gui_get_focus_owner() == j.code_edit, "web join screen: code field only, focused")
	check(not j.connect_to("192.168.0.20:7777") and j.status.text.begins_with("Invalid room code")
			and Net.session == null, "web join screen: an address is not a room code")
	check(not j.connect_to("") and j.status.text == "Enter a room code", "web join screen: empty")
	j.queue_free()
	await frames(2)

	# Desktop with codes: both fields, code first; recent hosts shown.
	_set_caps(false, true)
	j = spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(3)
	check(j.code_edit.is_visible_in_tree() and j.address_edit.is_visible_in_tree() and j.recent_rows().size() == 1
			and get_viewport().gui_get_focus_owner() == j.code_edit, "desktop+codes join screen: code first, then address + recent")
	check(not j.connect_to("bad host!") and j.status.text.begins_with("Invalid room code or address"),
			"desktop+codes join screen: junk names both kinds")
	j.queue_free()
	await frames(2)

	# Without codes: the address field only (as before).
	_set_caps(false, false)
	j = spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(3)
	check(not j.code_edit.is_visible_in_tree() and j.address_edit.is_visible_in_tree()
			and get_viewport().gui_get_focus_owner() == j.address_edit, "desktop join screen: no code field")
	# A code-shaped text without room codes is taken as a host name (Net.join as_address): not run here, it would resolve DNS.
	j.queue_free()
	await frames(2)

	# A web invite at boot: the screen fills the code and joins.
	_set_caps(true, true)
	JoinOnlineScreen.pending_code = CODE
	j = spawn(Game.SCENE_JOIN_ONLINE) as JoinOnlineScreen
	await frames(2)
	check(j.code_edit.text == CODE and JoinOnlineScreen.pending_code == ""
			and (j.connecting or j.status.text.begins_with("Could not connect")),
			"pending code: prefilled and joined at once (%s)" % j.status.text)
	j.cancel_connect()
	Net.leave()
	j.queue_free()
	await frames(2)
	Net.settings.recent_hosts.clear()
	_set_caps(_real_web, _real_webrtc)


func _test_background_warning() -> void:
	var w := BackgroundTabWarning.new()
	add_child(w)
	await frames(1)
	w.page_hidden(1000)
	w.page_shown(60000)
	check(not w.is_showing(), "tab warning: offline, never")
	Net.start_host(LoopbackNetwork.new(1).create_host())
	var min_ms := int(UiTheme.tuning().background_tab_min_hidden_seconds * 1000.0)
	w.page_hidden(1000)
	w.page_shown(1000 + min_ms / 2)
	check(not w.is_showing(), "tab warning: a short blur doesn't warn")
	w.page_hidden(1000)
	w.page_shown(1000 + min_ms * 3)
	check(w.is_showing(), "tab warning: back after being hidden online -> warning")
	Net.leave()
	await frames(2)
	check(not w.is_showing(), "tab warning: hides once offline")
	w.queue_free()
	await frames(1)
