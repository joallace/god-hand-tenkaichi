extends Node
## Autoload "Net": the online session's lifetime across scenes
## (SPEC_ONLINE.md §4). Offline play never touches it (`session == null`).
##
##   Net.host_room()          open a room with a room code (WebRTC; the code
##                            arrives later: room_code_changed / room_code)
##   Net.host()               open a direct-IP room on the settings' port
##                            (ENet + UPnP; desktop only)
##   Net.join("K7QX2M")       join by room code (or an invite URL holding
##   Net.join("1.2.3.4:7777") room=), else by address (desktop only);
##                            join_succeeded / join_failed
##   Net.leave()              close the room / leave it
##
## While a room is open, `room` (OnlineRoom) holds the host-authoritative
## lobby (LobbyModel), the phase (lobby / match / results), pause and rematch
## state. Net pumps the session every physics frame, except while a match's
## RollbackDriver runs it (`driver`, set by the match scene). A room's
## `match_starting` starts the match on every peer (Game.start_match).
##
## Losing the room outside a match (host left, timeout, kicked) leaves the
## session, stores a message in `pending_message` (the main menu shows and
## clears it) and goes to the main menu. During a match the driver aborts
## and the match scene does the same through `end_with_message`.
##
## Backends (PlatformCaps): room codes (WebRtcTransport through a signaling
## server, `signaling_url()`) where `room_codes()`, direct IP (EnetTransport)
## where `direct_ip()` (not web). `backend` says which one the open session
## uses. Without either, host()/host_room()/join() return ERR_UNAVAILABLE
## and the menus hide every online entry (`online_available()`).
##
## Web join links: `<page>?room=CODE` (`invite_text()` on web). At boot the
## page's `room` param lands in `boot_join_code` (the main menu opens the
## join screen with it) and is removed from the address bar.

## Guest: the host accepted us (the lobby scene is next).
signal join_succeeded()
## Guest: connecting failed or the host refused (text is user-facing).
signal join_failed(reason: int, text: String)
## The session ended (any role, any reason except our own leave()).
signal session_closed(reason: int, text: String)
## Room-code host: the signaling server gave the room its code ("" = the
## code is gone: signaling lost).
signal room_code_changed(code: String)
## Room-code host: a signaling problem to show (`signaling_error_text`).
signal signaling_problem(text: String)

## Room codes (docs/web_online.md "Signaling protocol"): this many chars from
## ROOM_CODE_ALPHABET (no 0/O/1/I), matched case-insensitively.
const ROOM_CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const ROOM_CODE_LENGTH := 6
## Page query params: the room to join, and a signaling server override.
const PARAM_ROOM := "room"
const PARAM_SIGNAL := "signal"
const SIGNALING_LOST_TEXT := "Lost the room server: no one new can join (players in the room keep playing)"
const SIGNALING_ERROR_FALLBACK := "Room server error"
const CONNECT_FAILED_TEXT := "Could not connect"

var settings: OnlineSettings
var transport: Transport
var session: Session
var room: OnlineRoom
var upnp := UpnpHelper.new()
## The running match's driver (the match scene sets/clears it).
var driver: RollbackDriver
## Address text of the last direct-IP join() (recent hosts); "" for codes.
var join_address: String = ""
## Room code of the last room-code join(); "" for addresses.
var join_code: String = ""
## Backend of the open session (NONE offline, and for tests' loopback).
var backend: PlatformCaps.NetBackend = PlatformCaps.NetBackend.NONE
## Room-code host: the room's code once the signaling server sent it.
var room_code: String = ""
## Room-code host: the last signaling problem (user-facing), "" = none.
var signaling_error_text: String = ""
## Web: the room code from the page's `?room=` at boot (the main menu takes
## it and clears it); "" = none.
var boot_join_code: String = ""
## A message for the main menu ("Host left the session", ...); "" = none.
var pending_message: String = ""
## Run Net's pump from _physics_process (tests drive update() by hand).
var auto_pump := true


func _ready() -> void:
	settings = OnlineSettings.load_from()
	if WebPage.is_browser():
		_read_boot_link()
		add_child(BackgroundTabWarning.new())


func _physics_process(_delta: float) -> void:
	if auto_pump:
		update()


## One frame: UPnP results, then (outside a match) the session and room.
func update() -> void:
	upnp.poll()
	if session == null or driver != null:
		return
	session.update()
	if room != null:
		room.tick()


## This platform can host or join at all (menus show online entries).
func online_available() -> bool:
	return PlatformCaps.online()


func is_online() -> bool:
	return session != null and session.state != Session.State.CLOSED


func is_host() -> bool:
	return session != null and session.is_host()


func local_peer() -> int:
	return session.local_peer_id if session != null else 0


# --- open / close ---------------------------------------------------------------

## Host a direct-IP room on `port` (settings' port when 0). Returns an Error
## (ERR_CANT_CREATE: the port is in use; ERR_UNAVAILABLE: no direct IP
## here). Starts a UPnP mapping.
func host(port: int = 0) -> Error:
	leave()
	if not PlatformCaps.direct_ip():
		return ERR_UNAVAILABLE
	var p := port if port > 0 else settings.host_port()
	var t := EnetTransport.new()
	var err := t.host(p, Tuning.net.max_humans - 1)
	if err != OK:
		return err
	start_host(t)
	backend = PlatformCaps.NetBackend.ENET
	upnp.start(p)
	return OK


## Host a room-code room. Returns at once (ERR_UNAVAILABLE: no room codes
## here; else the signaling/transport error); the room is open for the lobby
## right away and its code arrives later (room_code_changed). Signaling
## trouble shows in `signaling_error_text` (signaling_problem).
func host_room() -> Error:
	leave()
	if not PlatformCaps.room_codes():
		return ERR_UNAVAILABLE
	var sig := SignalingClient.new()
	var err := sig.connect_to_url(signaling_url())
	if err != OK:
		return err
	var t := WebRtcTransport.new()
	start_host(t)
	backend = PlatformCaps.NetBackend.WEBRTC
	watch_signaling(t)
	err = t.host_room(sig, game_id(), Tuning.net.max_humans - 1)
	if err != OK:
		leave()
	return err


## Join by room code / invite URL (room codes), or by address (IP[:PORT],
## hostname, [IPv6]:PORT; default port if omitted; direct IP); see
## parse_join_text. Returns an Error for unusable text
## (ERR_INVALID_PARAMETER, also for an address where there is no direct IP;
## ERR_UNAVAILABLE: no online here, or a code without room codes); otherwise
## the outcome arrives as join_succeeded or join_failed.
func join(text: String) -> Error:
	leave()
	if not online_available():
		return ERR_UNAVAILABLE
	var p := parse_join_text(text)
	match p["kind"]:
		"code":
			return _join_code(p["code"], p["signal"])
		"address":
			if not PlatformCaps.direct_ip():
				return ERR_INVALID_PARAMETER
			var t := EnetTransport.new()
			var err := t.join(p["address"], Tuning.net.default_port)
			if err != OK:
				return err
			start_guest(t)
			backend = PlatformCaps.NetBackend.ENET
			join_address = p["address"]
			return OK
	return ERR_INVALID_PARAMETER


func _join_code(code: String, signal_override: String) -> Error:
	if not PlatformCaps.room_codes():
		return ERR_UNAVAILABLE
	var sig := SignalingClient.new()
	var err := sig.connect_to_url(signal_override if not signal_override.is_empty() else signaling_url())
	if err != OK:
		return err
	var t := WebRtcTransport.new()
	start_guest(t)
	backend = PlatformCaps.NetBackend.WEBRTC
	join_code = code
	err = t.join_room(sig, code, game_id())
	if err != OK:
		leave()
	return err


## Host over any transport (tests: LoopbackTransport).
func start_host(t: Transport) -> void:
	leave()
	transport = t
	session = Session.create_host(t, settings.player_name, {"content_hash": ContentHash.compute()})
	_open_room()


## Guest over any transport (tests: LoopbackTransport).
func start_guest(t: Transport) -> void:
	leave()
	transport = t
	session = Session.create_guest(t, settings.player_name, {"content_hash": ContentHash.compute()})
	session.welcomed.connect(_on_welcomed)
	session.rejected.connect(_on_rejected)
	_open_room()


## Connect a room-code transport's signaling signals (host_room does; tests
## call it with a stand-in transport that declares the same signals).
func watch_signaling(t: Transport) -> void:
	if t.has_signal(&"room_opened"):
		t.connect(&"room_opened", _on_room_opened)
	if t.has_signal(&"signaling_error"):
		t.connect(&"signaling_error", _on_signaling_error)
	if t.has_signal(&"signaling_lost"):
		t.connect(&"signaling_lost", _on_signaling_lost)


## Leave the room (guest) or close it (host). No signals.
func leave() -> void:
	if session != null:
		session.close()
	upnp.stop()
	if room != null:
		room.detach()
	session = null
	transport = null
	room = null
	driver = null
	backend = PlatformCaps.NetBackend.NONE
	join_address = ""
	join_code = ""
	room_code = ""
	signaling_error_text = ""


## Leave and go to the main menu showing `text`.
func end_with_message(text: String) -> void:
	leave()
	pending_message = text
	Game.goto(Game.SCENE_MAIN_MENU)


## The input delay this peer uses for a match about to start: the settings'
## fixed delay, or auto from the worst RTT. A guest's frames reach other
## guests through the host, so with 3+ peers the guest's path is two hops.
func input_delay_for_match() -> int:
	if not settings.is_auto_delay():
		return settings.input_delay
	if session == null:
		return Tuning.net.input_delay_min
	var rtt := session.rtt_max_ms()
	if not session.is_host() and session.peer_ids().size() > 2:
		rtt *= 2.0
	return TimeSync.auto_input_delay(rtt)


## Text for a Protocol.Reason (REJECT, BYE, DROP, session end).
static func reason_text(reason: int, detail: String = "") -> String:
	var t := ""
	match reason:
		Protocol.Reason.VERSION:
			t = "Version mismatch"
		Protocol.Reason.CONTENT:
			t = "Game data mismatch"
		Protocol.Reason.ROOM_FULL:
			t = "Room is full"
		Protocol.Reason.IN_PROGRESS:
			t = "Match in progress (not joinable)"
		Protocol.Reason.BAD_NAME:
			t = "Invalid profile name"
		Protocol.Reason.PLATFORM:
			# The detail already says it all (Session.cross_play_text).
			return detail if not detail.is_empty() else "Cross-play unavailable"
		Protocol.Reason.HOST_CLOSING:
			t = "Host closed the room"
		Protocol.Reason.LEFT:
			t = "Host left the session"
		Protocol.Reason.TIMEOUT:
			t = "Connection timed out"
		Protocol.Reason.DISCONNECTED:
			t = "Connection lost"
		Protocol.Reason.DESYNC:
			t = "Connection error (desync)"
		_:
			t = "Connection error"
	return t if detail.is_empty() else "%s: %s" % [t, detail]


# --- room codes: signaling server, invite links, join text -----------------------

## The build id the signaling server matches between host and guests
## (the contract's "Protocol.VERSION" is Protocol.PROTOCOL_VERSION).
static func game_id() -> String:
	return "%d:%s" % [Protocol.PROTOCOL_VERSION, ContentHash.compute()]


## The signaling server to use: the Settings override, else the default.
func signaling_url() -> String:
	return resolve_signaling_url(settings.signaling_url, PlatformCaps.web, WebPage.location(),
			Tuning.net.signaling_url, Tuning.net.signaling_port)


## The signaling server used when Settings has no override (its placeholder).
func default_signaling_url() -> String:
	return resolve_signaling_url("", PlatformCaps.web, WebPage.location(),
			Tuning.net.signaling_url, Tuning.net.signaling_port)


## `override` (Settings) if set; on web a valid `?signal=` in the page's
## query, else the page's own host on `port` (wss when the page is https);
## otherwise (desktop, or a page location we can't read) `desktop_url`.
## `page` has WebPage.location()'s keys ("protocol", "hostname", "search").
static func resolve_signaling_url(override: String, on_web: bool, page: Dictionary,
		desktop_url: String, port: int) -> String:
	if not override.strip_edges().is_empty():
		return override.strip_edges()
	if on_web:
		var q := parse_query(str(page.get("search", "")))
		var sig := str(q.get(PARAM_SIGNAL, "")).strip_edges()
		if OnlineSettings.is_valid_signaling_url(sig):
			return sig
		var host_name := str(page.get("hostname", ""))
		if not host_name.is_empty():
			if host_name.contains(":") and not host_name.begins_with("["):
				host_name = "[%s]" % host_name
			var scheme := "wss" if str(page.get("protocol", "")) == "https:" else "ws"
			return "%s://%s:%d" % [scheme, host_name, port]
	return desktop_url


## What to share for the open room-code room: the invite URL on web (the
## page's own URL + ?room=CODE), the bare code elsewhere; "" without a code.
func invite_text() -> String:
	if room_code.is_empty():
		return ""
	var href := str(WebPage.location().get("href", ""))
	return invite_url(href, room_code) if not href.is_empty() else room_code


## `href` without its query and fragment, plus ?room=CODE (and the page's
## `signal` param, if it had one).
static func invite_url(href: String, code: String) -> String:
	var base := href.get_slice("#", 0)
	var q := {}
	var at := base.find("?")
	if at >= 0:
		q = parse_query(base.substr(at))
		base = base.substr(0, at)
	var out := "%s?%s=%s" % [base, PARAM_ROOM, code]
	var sig := str(q.get(PARAM_SIGNAL, ""))
	if not sig.is_empty():
		out += "&%s=%s" % [PARAM_SIGNAL, sig.uri_encode()]
	return out


## `href` with the `param` query param removed (others and the fragment kept).
static func strip_query_param(href: String, param: String) -> String:
	var hash_at := href.find("#")
	var frag := href.substr(hash_at) if hash_at >= 0 else ""
	var base := href.substr(0, hash_at) if hash_at >= 0 else href
	var at := base.find("?")
	if at < 0:
		return href
	var kept := PackedStringArray()
	for part in base.substr(at + 1).split("&", false):
		if part.get_slice("=", 0).uri_decode() != param:
			kept.append(part)
	var query := "?" + "&".join(kept) if not kept.is_empty() else ""
	return base.substr(0, at) + query + frag


## "?a=1&b=x%20y" (leading ? optional, fragment ignored) -> {"a": "1",
## "b": "x y"}; the first occurrence of a key wins; "+" decodes as a space.
static func parse_query(search: String) -> Dictionary:
	var out := {}
	var s := search.get_slice("#", 0)
	if s.begins_with("?"):
		s = s.substr(1)
	for part in s.split("&", false):
		var k := part.get_slice("=", 0).replace("+", " ").uri_decode()
		var v := part.substr(part.find("=") + 1).replace("+", " ").uri_decode() if part.contains("=") else ""
		if not k.is_empty() and not out.has(k):
			out[k] = v
	return out


## Upper case, spaces / dashes / underscores dropped ("k7q-x2m" -> "K7QX2M").
static func normalize_room_code(text: String) -> String:
	var s := text.strip_edges().to_upper()
	for sep in [" ", "-", "_", "\t"]:
		s = s.replace(sep, "")
	return s


## ROOM_CODE_LENGTH chars of ROOM_CODE_ALPHABET (already normalized).
static func is_room_code(code: String) -> bool:
	if code.length() != ROOM_CODE_LENGTH:
		return false
	for c in code:
		if not ROOM_CODE_ALPHABET.contains(c):
			return false
	return true


## What a join field's text is: {"kind": "code" | "address" | "invalid",
## "code": the normalized code, "signal": an invite URL's valid `signal`
## param or "", "address": the stripped address, "error": why it's invalid}.
## Text holding `room=` is an invite link (its room param must be a code);
## text that is a room code once spaces/dashes are dropped (and has no "."
## or ":") is a code; a valid EnetTransport address is an address (whether
## this platform can join one is Net.join's business). A host whose name
## looks like a code needs its port ("name:7777").
static func parse_join_text(text: String) -> Dictionary:
	var out := {"kind": "invalid", "code": "", "signal": "", "address": "", "error": ""}
	var t := text.strip_edges()
	if t.is_empty():
		out["error"] = "empty"
		return out
	if t.contains(PARAM_ROOM + "="):
		var at := t.find("?")
		var q := parse_query(t.substr(at) if at >= 0 else t)
		var link_code := normalize_room_code(str(q.get(PARAM_ROOM, "")))
		if not is_room_code(link_code):
			out["error"] = "not a valid room code"
			return out
		var sig := str(q.get(PARAM_SIGNAL, "")).strip_edges()
		out["kind"] = "code"
		out["code"] = link_code
		out["signal"] = sig if OnlineSettings.is_valid_signaling_url(sig) else ""
		return out
	var code := normalize_room_code(t)
	if is_room_code(code) and not t.contains(".") and not t.contains(":"):
		out["kind"] = "code"
		out["code"] = code
		return out
	var parsed := EnetTransport.parse_address(t, Tuning.net.default_port)
	if parsed["ok"]:
		out["kind"] = "address"
		out["address"] = t
	else:
		out["error"] = str(parsed["error"])
	return out


## The room code in a page query ("?room=k7qx2m" -> "K7QX2M"), "" if none.
static func room_code_from_query(search: String) -> String:
	var code := normalize_room_code(str(parse_query(search).get(PARAM_ROOM, "")))
	return code if is_room_code(code) else ""


## Web boot: take ?room= from the page (boot_join_code) and drop it from the
## address bar so a refresh or Back doesn't join again.
func _read_boot_link() -> void:
	var page := WebPage.location()
	var search := str(page.get("search", ""))
	if not parse_query(search).has(PARAM_ROOM):
		return
	boot_join_code = room_code_from_query(search)
	WebPage.replace_url(strip_query_param(str(page.get("href", "")), PARAM_ROOM))


# --- internals ------------------------------------------------------------------

func _open_room() -> void:
	room = OnlineRoom.new(session)
	room.match_starting.connect(_on_match_starting)
	session.session_ended.connect(_on_session_ended)


func _on_welcomed(_peer: int) -> void:
	if not join_address.is_empty():
		settings.add_recent_host(join_address, session.peer_name(Transport.HOST_PEER))
		settings.save()
	join_succeeded.emit()


func _on_rejected(reason: int, detail: String) -> void:
	join_failed.emit(reason, reason_text(reason, detail))


func _on_session_ended(reason: int) -> void:
	var was_connected := room != null and room.welcomed
	var text := reason_text(reason)
	session_closed.emit(reason, text)
	if not was_connected:
		# Never got in: the join screen shows why (rejects already did).
		if reason != Protocol.Reason.VERSION and reason != Protocol.Reason.CONTENT \
				and reason != Protocol.Reason.ROOM_FULL and reason != Protocol.Reason.IN_PROGRESS \
				and reason != Protocol.Reason.BAD_NAME and reason != Protocol.Reason.PLATFORM:
			join_failed.emit(reason, connect_failed_text() if reason == Protocol.Reason.TIMEOUT \
				or reason == Protocol.Reason.DISCONNECTED else text)
		leave()
		return
	if driver != null:
		return  # the match scene ends the match (driver.aborted)
	end_with_message(text)


## Why a guest never got in: the transport's own reason when it has one
## (WebRtcTransport.last_error_text: room not found, a TURN relay needed...),
## else the generic text.
func connect_failed_text() -> String:
	var t := _transport_error_text()
	return t if not t.is_empty() else CONNECT_FAILED_TEXT


func _transport_error_text() -> String:
	if transport != null and transport.has_method(&"last_error_text"):
		return str(transport.call(&"last_error_text"))
	return ""


func _on_room_opened(code: String) -> void:
	room_code = code
	signaling_error_text = ""
	room_code_changed.emit(code)


func _on_signaling_error(_code: String, text: String) -> void:
	signaling_error_text = text if not text.is_empty() else SIGNALING_ERROR_FALLBACK
	signaling_problem.emit(signaling_error_text)


func _on_signaling_lost() -> void:
	signaling_error_text = SIGNALING_LOST_TEXT
	if not room_code.is_empty():
		room_code = ""
		room_code_changed.emit("")
	signaling_problem.emit(signaling_error_text)


func _on_match_starting(config: MatchConfig) -> void:
	Game.start_match(config)
