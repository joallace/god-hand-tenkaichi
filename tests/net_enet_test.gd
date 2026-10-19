extends Node
## EnetTransport: address parsing, and a real host + client on 127.0.0.1
## running a Session handshake and input exchange (skipped with a note if
## UDP can't be bound here).
## Run as a scene:  godot --headless res://tests/net_enet_test.tscn

## Real-time budget for the localhost exchange.
const MAX_ITERATIONS := 400
const ITERATION_MS := 5
const TICKS := 30

var _failures := 0


func _ready() -> void:
	_test_parse_address()
	_test_localhost()
	print("NET ENET TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _parsed(text: String, host: String, port: int) -> void:
	var a := EnetTransport.parse_address(text, 7777)
	_check(a["ok"] and a["host"] == host and a["port"] == port,
		"parse '%s' -> %s port %d (%s)" % [text, host, port, a])


func _refused(text: String) -> void:
	var a := EnetTransport.parse_address(text, 7777)
	_check(not a["ok"] and not String(a["error"]).is_empty(), "parse '%s' refused (%s)" % [text, a["error"]])


func _test_parse_address() -> void:
	_parsed("192.168.0.12:7000", "192.168.0.12", 7000)
	_parsed("  10.0.0.1  ", "10.0.0.1", 7777)
	_parsed("example.org", "example.org", 7777)
	_parsed("my-host.lan:1234", "my-host.lan", 1234)
	_parsed("[::1]:9000", "::1", 9000)
	_parsed("[2001:db8::5]", "2001:db8::5", 7777)
	_parsed("2001:db8::5", "2001:db8::5", 7777)
	_parsed("localhost", "localhost", 7777)
	_refused("")
	_refused("host:")
	_refused("host:abc")
	_refused("host:0")
	_refused("host:70000")
	_refused("[::1")
	_refused("[::1]x")
	_refused("[::1]:")
	_refused("[1.2.3.4]:80")
	_refused("bad_host:80")
	_refused("-bad.example")
	_refused("a..b")
	_refused(":7777")
	_refused("1:2:3:zz")


func _test_localhost() -> void:
	var ht := EnetTransport.new()
	var err := ht.host(0, Tuning.net.max_humans, "127.0.0.1")
	if err != OK:
		print("NOTE: can't bind UDP on 127.0.0.1 (%s); skipping the ENet localhost test" % error_string(err))
		return
	var port := ht.local_port()
	_check(port > 0, "host bound an ephemeral port (%d)" % port)
	var ct := EnetTransport.new()
	if not _check(ct.join("127.0.0.1:%d" % port, Tuning.net.default_port) == OK, "client starts connecting"):
		ht.close()
		return
	_check(ct.join("not a host!", 1) == ERR_INVALID_PARAMETER, "join refuses a bad address")
	ct.join("127.0.0.1:%d" % port, Tuning.net.default_port)
	var host := Session.create_host(ht, "Host")
	var guest := Session.create_guest(ct, "Guest")
	var i := 0
	while guest.state != Session.State.CONNECTED and i < MAX_ITERATIONS:
		host.update()
		guest.update()
		OS.delay_msec(ITERATION_MS)
		i += 1
	if not _check(guest.state == Session.State.CONNECTED and guest.local_peer_id == Transport.FIRST_GUEST_PEER,
			"handshake over UDP (%d iterations)" % i):
		host.close()
		guest.close()
		return
	_check(ht.connected_peers() == [Transport.FIRST_GUEST_PEER] and ct.connected_peers() == [Transport.HOST_PEER],
		"transport peer ids: host numbers the client 2, client sees host 1")
	var owners := {0: Transport.HOST_PEER, 1: guest.local_peer_id}
	host.begin_match(owners)
	guest.begin_match(owners)
	for t in range(1, TICKS + 1):
		var f := InputFrame.new()
		f.move_x = t
		host.submit_local_input(0, t, f)
		var g := InputFrame.new()
		g.move_y = -t
		guest.submit_local_input(1, t, g)
	var cmds := []
	guest.command_received.connect(func(c: Dictionary) -> void: cmds.append(c))
	host.send_command({"tick": 5, "kind": 1})
	var snaps := []
	guest.snapshot_received.connect(func(t: int, s: Dictionary, _e: Dictionary) -> void: snaps.append([t, s]))
	var big := {"pad": PackedByteArray(), "tick": 9}
	(big["pad"] as PackedByteArray).resize(Tuning.net.max_packet_bytes * 4)
	host.send_snapshot(guest.local_peer_id, 9, big)
	i = 0
	while i < MAX_ITERATIONS and (guest.history.last_confirmed_tick(0) < TICKS
			or host.history.last_confirmed_tick(1) < TICKS or cmds.is_empty() or snaps.is_empty()):
		host.update()
		guest.update()
		OS.delay_msec(ITERATION_MS)
		i += 1
	var ok := true
	for t in range(1, TICKS + 1):
		var a := guest.history.confirmed_frame(0, t)
		var b := host.history.confirmed_frame(1, t)
		ok = ok and a != null and a.move_x == t and b != null and b.move_y == -t
	_check(ok, "inputs cross both ways over UDP")
	_check(cmds.size() == 1 and snaps.size() == 1 and snaps[0][1] == big, "reliable CMD and bulk SNAPSHOT arrive")
	var ended := []
	guest.session_ended.connect(func(r: int) -> void: ended.append(r))
	host.close()
	i = 0
	while ended.is_empty() and i < MAX_ITERATIONS:
		guest.update()
		OS.delay_msec(ITERATION_MS)
		i += 1
	_check(ended.size() == 1, "guest learns the host closed (%s)" % [ended])
	guest.close()
