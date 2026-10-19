extends Node
## Autoload "Net": the online session's lifetime across scenes
## (SPEC_ONLINE.md §4). Offline play never touches it (`session == null`).
##
##   Net.host()               open a room on the settings' port (+ UPnP)
##   Net.join("1.2.3.4:7777") connect as a guest; join_succeeded / join_failed
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

## Guest: the host accepted us (the lobby scene is next).
signal join_succeeded()
## Guest: connecting failed or the host refused (text is user-facing).
signal join_failed(reason: int, text: String)
## The session ended (any role, any reason except our own leave()).
signal session_closed(reason: int, text: String)

var settings: OnlineSettings
var transport: Transport
var session: Session
var room: OnlineRoom
var upnp := UpnpHelper.new()
## The running match's driver (the match scene sets/clears it).
var driver: RollbackDriver
## Address text of the last join() (recent hosts).
var join_address: String = ""
## A message for the main menu ("Host left the session", ...); "" = none.
var pending_message: String = ""
## Run Net's pump from _physics_process (tests drive update() by hand).
var auto_pump := true


func _ready() -> void:
	settings = OnlineSettings.load_from()


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


func is_online() -> bool:
	return session != null and session.state != Session.State.CLOSED


func is_host() -> bool:
	return session != null and session.is_host()


func local_peer() -> int:
	return session.local_peer_id if session != null else 0


# --- open / close ---------------------------------------------------------------

## Host a room on `port` (settings' port when 0). Returns an Error
## (ERR_CANT_CREATE: the port is in use). Starts a UPnP mapping.
func host(port: int = 0) -> Error:
	leave()
	var p := port if port > 0 else settings.host_port()
	var t := EnetTransport.new()
	var err := t.host(p, Tuning.net.max_humans - 1)
	if err != OK:
		return err
	start_host(t)
	upnp.start(p)
	return OK


## Join `address` (IP[:PORT], hostname, [IPv6]:PORT; default port if
## omitted). Returns an Error for an unusable address; otherwise the outcome
## arrives as join_succeeded or join_failed.
func join(address: String) -> Error:
	leave()
	var t := EnetTransport.new()
	var err := t.join(address, Tuning.net.default_port)
	if err != OK:
		return err
	join_address = address.strip_edges()
	start_guest(t)
	return OK


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


# --- internals ------------------------------------------------------------------

func _open_room() -> void:
	room = OnlineRoom.new(session)
	room.match_starting.connect(_on_match_starting)
	session.session_ended.connect(_on_session_ended)


func _on_welcomed(_peer: int) -> void:
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
				and reason != Protocol.Reason.BAD_NAME:
			join_failed.emit(reason, "Could not connect" if reason == Protocol.Reason.TIMEOUT \
				or reason == Protocol.Reason.DISCONNECTED else text)
		leave()
		return
	if driver != null:
		return  # the match scene ends the match (driver.aborted)
	end_with_message(text)


func _on_match_starting(config: MatchConfig) -> void:
	Game.start_match(config)
