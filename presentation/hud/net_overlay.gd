class_name NetOverlay
extends CanvasLayer
## Debug net stats for online matches (SPEC_ONLINE.md §10.6), a small panel
## in the bottom-left corner: role and input delay, ping per peer (relayed
## peers marked), packet loss when the transport reports it, rollbacks per
## second and their average depth, stalls, confirmed tick and the last
## checkpoint hash tick, resyncs and dropped packets.
## Shown while Net.settings.net_overlay is on; F3 (or the pause menu's Net
## Stats) toggles and saves it. Read-only: it only reads the driver/session.

const LAYER := 60
const TOGGLE_KEY := KEY_F3
## Optional transport method (EnetTransport) for packet loss in percent.
const LOSS_METHOD := &"packet_loss"

var driver: RollbackDriver
var label: Label

var _panel: PanelContainer
var _window_time := 0.0
var _window_rollbacks := 0
var _rollback_rate := 0.0
var _hash_count := 0
var _hash_last := -1


func _init() -> void:
	name = "NetOverlay"
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(p_driver: RollbackDriver) -> void:
	driver = p_driver
	var t := Tuning.hud
	var root := Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = t.net_overlay_bg_color
	sb.set_content_margin_all(t.net_overlay_padding)
	_panel.add_theme_stylebox_override("panel", sb)
	root.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE)
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.position += Vector2(t.net_overlay_margin, -t.net_overlay_margin)

	label = Label.new()
	label.name = "Stats"
	var ls := LabelSettings.new()
	ls.font_size = t.net_overlay_font_size
	ls.font_color = t.net_overlay_color
	label.label_settings = ls
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(label)
	refresh()


## Flip and save the user setting.
func toggle() -> void:
	Net.settings.net_overlay = not Net.settings.net_overlay
	Net.settings.save()
	refresh()


func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == TOGGLE_KEY:
		toggle()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if driver == null:
		return
	_window_time += delta
	if _window_time >= Tuning.hud.net_overlay_rate_window:
		_rollback_rate = (driver.rollbacks - _window_rollbacks) / _window_time
		_window_rollbacks = driver.rollbacks
		_window_time = 0.0
	refresh()


## Visibility from the setting, then the text (when shown).
func refresh() -> void:
	visible = Net.settings.net_overlay
	if visible and driver != null and driver.session != null and label != null:
		label.text = stats_text()


func stats_text() -> String:
	var s := driver.session
	var lines: PackedStringArray = []
	lines.append("NET %s · peer %d · delay %df" % ["host" if s.is_host() else "guest", s.local_peer_id, driver.input_delay])
	var linked := s.link_peers()
	for peer in s.peer_ids():
		if peer == s.local_peer_id:
			continue
		var nm := s.peer_name(peer)
		if not peer in linked:
			lines.append("  %s: via host" % nm)
			continue
		var line := "  %s: %s" % [nm, _ms(s.rtt_ms(peer))]
		var loss := _loss(peer)
		if loss >= 0.0:
			line += " · loss %.1f%%" % loss
		lines.append(line)
	var depth := float(driver.rollback_ticks) / driver.rollbacks if driver.rollbacks > 0 else 0.0
	lines.append("rollbacks %.1f/s · avg depth %.1f · total %d" % [_rollback_rate, depth, driver.rollbacks])
	lines.append("stalls %d frames · now %d" % [driver.stall_frames, driver.stalled_for])
	lines.append("tick %d · confirmed %d · hash @%s" % [driver.director.tick if driver.director != null else 0,
		driver.confirmed_tick, _last_hash_tick()])
	lines.append("resyncs %d · dropped packets %d" % [driver.resyncs, s.dropped_packets])
	return "\n".join(lines)


func _ms(v: float) -> String:
	return "-- ms" if v < 0.0 else "%d ms" % roundi(v)


## Packet loss in percent, or -1 when the transport can't tell.
func _loss(peer: int) -> float:
	var t := driver.session.transport
	if t == null or not t.has_method(LOSS_METHOD):
		return -1.0
	return float(t.call(LOSS_METHOD, peer))


## Latest checkpoint tick (rescanned only when a checkpoint was added).
func _last_hash_tick() -> String:
	if driver.confirmed_hashes.size() != _hash_count:
		_hash_count = driver.confirmed_hashes.size()
		_hash_last = -1
		for tick: int in driver.confirmed_hashes:
			_hash_last = maxi(_hash_last, tick)
	return "--" if _hash_last < 0 else str(_hash_last)
