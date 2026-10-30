extends Node
## HELLO `platform` (desktop <-> browser cross-play, docs/web_online.md):
## Protocol round-trips it (and decodes an older build's HELLO without it),
## WELCOME / PEERS share every member's platform, the host stores it per
## peer (Session.peer_platform / includes_platform), rejects unknown
## platforms (PROTOCOL) and, with Tuning.net.cross_play off, guests of the
## other platform (PLATFORM).
## Run as a scene:  godot --headless res://tests/net_platform_test.tscn

const CH_R := Transport.Channel.RELIABLE
const Reason := Protocol.Reason
const WEB := Protocol.PLATFORM_WEB
const DESKTOP := Protocol.PLATFORM_DESKTOP

var _failures := 0


func _ready() -> void:
	var saved_cross_play := Tuning.net.cross_play
	_test_protocol()
	_test_platforms_shared()
	Tuning.net.cross_play = true
	_test_join(DESKTOP, WEB, -1, "cross-play on: web guest joins a desktop host")
	_test_join(WEB, DESKTOP, -1, "cross-play on: desktop guest joins a web host")
	_test_join(DESKTOP, "toaster", Reason.PROTOCOL, "unknown platform")
	Tuning.net.cross_play = false
	_test_join(DESKTOP, WEB, Reason.PLATFORM, "cross-play off: web guest, desktop host")
	_test_join(WEB, DESKTOP, Reason.PLATFORM, "cross-play off: desktop guest, web host")
	_test_join(WEB, WEB, -1, "cross-play off: same platform still joins")
	Tuning.net.cross_play = saved_cross_play
	_test_old_build()
	_test_caps_config()
	_test_room_caps(WEB, true)
	_test_room_caps(DESKTOP, false)
	print("NET PLATFORM TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _test_protocol() -> void:
	var hello := {"engine_version": 0x040702, "game_build": "dev", "content_hash": "abc", "name": "Joe"}
	var m := Protocol.decode(Protocol.encode_hello(hello), CH_R)
	_check(m.get("platform") == PlatformCaps.platform_name() and m["platform"] in Protocol.PLATFORMS,
		"HELLO fills in this platform (%s)" % m.get("platform"))
	hello["platform"] = WEB
	m = Protocol.decode(Protocol.encode_hello(hello), CH_R)
	_check(m.get("platform") == WEB, "HELLO platform round-trips")
	# An older build's HELLO: no platform field at all.
	var old := hello.duplicate()
	old.erase("platform")
	old["protocol_version"] = Protocol.PROTOCOL_VERSION - 1
	old["reconnect_token"] = ""
	var raw := PackedByteArray([Protocol.Type.HELLO])
	raw.append_array(var_to_bytes(old))
	m = Protocol.decode(raw, CH_R)
	_check(m.get("type") == Protocol.Type.HELLO and m.get("platform") == "",
		"HELLO without platform (older build) decodes, platform \"\"")
	hello["platform"] = "x".repeat(Protocol.PLATFORM_MAX_LEN + 1)
	_check(Protocol.encode_hello(hello).is_empty(), "HELLO with an oversized platform is refused")
	hello["platform"] = 3
	_check(Protocol.encode_hello(hello).is_empty(), "HELLO with a non-string platform is refused")

	var plats := {1: DESKTOP, 2: WEB}
	m = Protocol.decode(Protocol.encode_welcome(2, "tok", {}, {1: "Host", 2: "Joe"}, plats), CH_R)
	_check(m.get("platforms") == plats, "WELCOME platforms round-trip")
	m = Protocol.decode(Protocol.encode_peers({1: "Host", 2: "Joe"}, plats), CH_R)
	_check(m.get("platforms") == plats, "PEERS platforms round-trip")
	_check(Protocol.encode_peers({1: "Host"}, {1: "toaster"}).is_empty(), "PEERS with an unknown platform is refused")
	_check(Protocol.encode_welcome(2, "", {}, {1: "Host"}, {"1": WEB}).is_empty(),
		"WELCOME with a non-peer platform key is refused")


## Host (desktop) + a web guest + a desktop guest: everyone sees everyone's
## platform.
func _test_platforms_shared() -> void:
	var net := LoopbackNetwork.new(5)
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host", {"content_hash": "abc", "platform": DESKTOP})
	var sessions: Array = [host]
	for plat: String in [WEB, DESKTOP]:
		var gt := net.create_client()
		sessions.append(Session.create_guest(gt, "G" + plat, {"content_hash": "abc", "platform": plat}))
		net.connect_client(gt, ht)
	_pump(net, sessions, 60)
	var web_guest: Session = sessions[1]
	var desk_guest: Session = sessions[2]
	if not _check(web_guest.state == Session.State.CONNECTED and desk_guest.state == Session.State.CONNECTED,
			"mixed room: both guests welcomed"):
		return
	var w := web_guest.local_peer_id
	var d := desk_guest.local_peer_id
	for s: Session in sessions:
		_check(s.peer_platform(Transport.HOST_PEER) == DESKTOP and s.peer_platform(w) == WEB
			and s.peer_platform(d) == DESKTOP,
			"peer %d sees every member's platform" % s.local_peer_id)
		_check(s.includes_platform(WEB) and s.includes_platform(DESKTOP), "peer %d: includes_platform" % s.local_peer_id)
	_check(host.peer_platform(99) == "", "unknown peer -> \"\"")
	# The web guest leaves: nobody is on web any more.
	web_guest.close()
	_pump(net, [host, desk_guest], 60)
	_check(host.peer_platform(w) == "" and not host.includes_platform(WEB), "host forgets a dropped peer's platform")
	_check(desk_guest.peer_platform(w) == "" and not desk_guest.includes_platform(WEB),
		"guests forget a dropped peer's platform")


## expect -1 = welcomed.
func _test_join(host_platform: String, guest_platform: String, expect: int, label: String) -> void:
	var net := LoopbackNetwork.new(9)
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host", {"content_hash": "abc", "platform": host_platform})
	var gt := net.create_client()
	var g := Session.create_guest(gt, "Guest", {"content_hash": "abc", "platform": guest_platform})
	net.connect_client(gt, ht)
	var got := []
	g.rejected.connect(func(r: int, detail: String) -> void: got.append([r, detail]))
	_pump(net, [host, g], 60)
	if expect < 0:
		_check(got.is_empty() and g.state == Session.State.CONNECTED
			and host.peer_platform(g.local_peer_id) == guest_platform, label)
		return
	_check(got.size() == 1 and got[0][0] == expect and g.state == Session.State.CLOSED
		and host.link_peers().is_empty(), "%s -> REJECT %d (%s)" % [label, expect, got[0][1] if not got.is_empty() else "none"])
	if expect == Reason.PLATFORM and not got.is_empty():
		_check(got[0][1] == Session.cross_play_text(host_platform, guest_platform), "%s: detail names both platforms" % label)
		_check(Net.reason_text(expect, got[0][1]) == got[0][1], "%s: the join screen shows that detail as is" % label)


## A guest of the previous protocol (no platform in HELLO) still gets a
## proper REJECT VERSION, not a silent drop.
func _test_old_build() -> void:
	var net := LoopbackNetwork.new(11)
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host", {"content_hash": "abc"})
	var gt := net.create_client()
	net.connect_client(gt, ht)
	var got := []
	for i in 60:
		net.advance_frame()
		host.receive()
		host.send_pending()
		for ev in gt.poll():
			if ev["type"] == Transport.EventType.CONNECTED:
				var old := Session.default_identity()
				old.erase("platform")
				old["protocol_version"] = Protocol.PROTOCOL_VERSION - 1
				old["content_hash"] = "abc"
				old["name"] = "Old"
				old["reconnect_token"] = ""
				var raw := PackedByteArray([Protocol.Type.HELLO])
				raw.append_array(var_to_bytes(old))
				gt.send(Transport.HOST_PEER, CH_R, raw)
			elif ev["type"] == Transport.EventType.PACKET:
				var m := Protocol.decode(ev["data"], ev["channel"])
				if m.get("type") == Protocol.Type.REJECT:
					got.append(m["reason"])
		gt.flush()
	_check(got == [Reason.VERSION], "old build's HELLO (no platform) -> REJECT VERSION (got %s)" % [got])


## Browser caps are plain config: apply_platform_caps fills them from
## Tuning, they survive the wire form, and the sim / driver read them.
func _test_caps_config() -> void:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.coop = CoopConfig.new()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.owner_peer = Transport.HOST_PEER + i
		cfg.players.append(p)
	_check(cfg.online_field_cap == 0 and cfg.rollback_frames() == Tuning.net.max_rollback_frames,
		"no caps by default (Tuning values)")
	_check(CoopRun.field_cap_for(cfg) == mini(Tuning.coop.field_cap, Tuning.coop.online_field_cap),
		"online field cap defaults to coop.online_field_cap")
	cfg.apply_platform_caps(true)
	_check(cfg.online_field_cap == Tuning.coop.online_field_cap_web
		and cfg.rollback_frames() == Tuning.net.max_rollback_frames_web, "web caps from Tuning")
	var wire := MatchConfig.from_dict(cfg.to_dict())
	_check(wire != null and wire.online_field_cap == cfg.online_field_cap
		and wire.max_rollback_frames == cfg.max_rollback_frames, "caps round-trip through to_dict/from_dict")
	cfg.online_field_cap = 3
	_check(CoopRun.field_cap_for(cfg) == mini(Tuning.coop.field_cap, 3), "CoopRun.field_cap_for reads the config cap")
	cfg.apply_platform_caps(false)
	_check(cfg.online_field_cap == 0 and cfg.max_rollback_frames == 0, "no web peer -> caps cleared")
	var bad := cfg.to_dict()
	bad["max_rollback_frames"] = "8"
	_check(MatchConfig.from_dict(bad) == null, "mistyped cap rejected")
	bad["max_rollback_frames"] = 1000
	_check(MatchConfig.from_dict(bad).max_rollback_frames == MatchConfig.MAX_ROLLBACK_FRAMES, "out-of-range cap clamped")
	# The driver takes its rollback window from the config.
	cfg.max_rollback_frames = 5
	var net := LoopbackNetwork.new(13)
	var host := Session.create_host(net.create_host(), "Host")
	var d := MatchDirector.new()
	add_child(d)
	var drv := RollbackDriver.new()
	drv.auto_run = false
	add_child(drv)
	drv.start(d, host, MatchConfig.from_dict(cfg.to_dict()), {}, 0)
	_check(drv.max_rollback_frames == 5, "RollbackDriver.max_rollback_frames = config's")
	drv.queue_free()
	d.queue_free()


## The host picks the caps into the config it starts (MATCH_START) when a
## member is on web, and leaves them off otherwise.
func _test_room_caps(guest_platform: String, expect_caps: bool) -> void:
	var net := LoopbackNetwork.new(17)
	var ht := net.create_host()
	var host := Session.create_host(ht, "Host", {"content_hash": "abc", "platform": DESKTOP})
	var gt := net.create_client()
	var g := Session.create_guest(gt, "Guest", {"content_hash": "abc", "platform": guest_platform})
	net.connect_client(gt, ht)
	_pump(net, [host, g], 60)
	var room := OnlineRoom.new(host)
	room.start_match()
	var cfg := room.last_config
	var label := "room with a %s guest" % guest_platform
	if not _check(cfg != null, "%s: match config built" % label):
		room.detach()
		return
	if expect_caps:
		_check(cfg.online_field_cap == Tuning.coop.online_field_cap_web
			and cfg.max_rollback_frames == Tuning.net.max_rollback_frames_web, "%s: host applies web caps" % label)
	else:
		_check(cfg.online_field_cap == 0 and cfg.max_rollback_frames == 0, "%s: no caps" % label)
	room.detach()


func _pump(net: LoopbackNetwork, sessions: Array, frames: int) -> void:
	for i in frames:
		net.advance_frame()
		for s: Session in sessions:
			s.receive()
			s.send_pending()
