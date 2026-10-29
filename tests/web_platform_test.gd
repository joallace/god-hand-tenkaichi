extends Node
## Headless test of the web (browser) platform gates: with PlatformCaps.web
## forced on, the menus hide every online entry and Quit, the Graphics page
## hides the rows the browser owns, Net refuses to open a session, UPnP
## stays idle and viewports never get an FSR upscaler. Run as a scene:
##   godot --headless res://tests/web_platform_test.tscn
## Settings.video is restored afterwards and never saved.

var _fails := 0
var _real_web := false
var _real_video := {}


func _ready() -> void:
	_real_web = PlatformCaps.web
	_real_video = Settings.video.to_dict()
	PlatformCaps.web = true
	_test_caps()
	_test_net()
	_test_viewport()
	await _test_main_menu()
	await _test_settings_screen()
	await _test_lobby()
	PlatformCaps.web = _real_web
	Settings.video.from_dict(_real_video)
	Settings.apply_video()
	_test_desktop_caps()
	print("WEB_PLATFORM %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
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


func _test_caps() -> void:
	check(not PlatformCaps.window_control() and not PlatformCaps.can_quit() and not PlatformCaps.upnp()
			and not PlatformCaps.fsr(), "web: no window control, quit, UPnP or FSR")
	check(PlatformCaps.net_backend() == PlatformCaps.NetBackend.NONE and not Net.online_available(),
			"web: no online backend yet")


func _test_desktop_caps() -> void:
	check(PlatformCaps.window_control() and PlatformCaps.can_quit() and PlatformCaps.upnp()
			and PlatformCaps.net_backend() == PlatformCaps.NetBackend.ENET and Net.online_available(),
			"desktop: window control, quit, UPnP and ENet online")


func _test_net() -> void:
	check(Net.host() == ERR_UNAVAILABLE and not Net.is_online(), "web: Net.host() refuses")
	check(Net.join("127.0.0.1:1") == ERR_UNAVAILABLE and not Net.is_online(), "web: Net.join() refuses")
	var u := UpnpHelper.new()
	u.start(Tuning.net.default_port)
	check(u.status == UpnpHelper.Status.IDLE, "web: UPnP start is a no-op")
	u.stop()


func _test_viewport() -> void:
	Settings.video.set_render_scale(Tuning.video.render_scale_steps[0])
	Settings.video.set_upscaler(VideoSettings.Upscaler.FSR2)
	var vp := SubViewport.new()
	add_child(vp)
	Settings.configure_viewport(vp)
	check(vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR
			and is_equal_approx(vp.scaling_3d_scale, Tuning.video.render_scale_steps[0]),
			"web: render scale applies, upscaler forced to bilinear")
	vp.queue_free()
	Settings.video.from_dict(_real_video)


func _test_main_menu() -> void:
	var m := spawn(Game.SCENE_MAIN_MENU) as Control
	await frames(3)
	var labels: Array = (m.get("_list") as Node).get_children().map(
			func(b: Node) -> String: return (b as Button).text if b is Button else "")
	check(labels == ["Play", "How to Play", "Settings"], "web main menu: no Join online / Quit (got %s)" % [labels])
	m.call("_on_how_to_play")
	await frames(2)
	var online_found := false
	for l in (m.get("_how_to") as Node).find_children("*", "Label", true, false):
		online_found = online_found or (l as Label).text == "Online"
	check(not online_found, "web how-to-play: no Online section")
	m.queue_free()
	await frames(2)


func _test_settings_screen() -> void:
	var s := spawn(Game.SCENE_SETTINGS) as SettingsScreen
	await frames(3)
	check(s.online == null and s.pages.size() == 3 and s.tab_buttons.size() == 3,
			"web settings: Graphics / Audio / Controls only")
	var g := s.graphics
	var hidden: Array = [g.mode_sel, g.size_sel, g.width_step, g.height_step, g.vsync_sel, g.upscaler_sel]
	check(hidden.all(func(c: Control) -> bool: return not c.visible), "web graphics: window, VSync, upscaler rows hidden")
	check([g.render_sel, g.fps_sel, g.smooth_sel, g.shadow_sel, g.ui_sel].all(
			func(c: Control) -> bool: return c.visible), "web graphics: render scale, FPS, smoothing, shadows, UI scale shown")
	check(not hidden.has(get_viewport().gui_get_focus_owner()), "web graphics: focus never lands on a hidden row")
	s.select_tab(s.current + 3)
	await frames(1)
	check(s.current == SettingsScreen.Tab.GRAPHICS, "web settings: tabs wrap over three pages")
	s.queue_free()
	await frames(2)


func _test_lobby() -> void:
	var l := spawn(Game.SCENE_LOBBY) as Lobby
	await frames(3)
	check(not (l.get("_room_button") as Button).visible, "web lobby: no room button")
	l.room_action()
	await frames(1)
	check(not Net.is_online() and not l.is_online(), "web lobby: room action does nothing")
	var hint_has_room := false
	for lab in l.find_children("*", "Label", true, false):
		hint_has_room = hint_has_room or (lab as Label).text.contains("TAB room")
	check(not hint_has_room, "web lobby: hint has no room keys")
	l.queue_free()
	await frames(2)
