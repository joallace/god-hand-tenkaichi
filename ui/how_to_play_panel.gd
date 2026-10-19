class_name HowToPlayPanel
extends Control
## Modal "How to play" overlay listing the default controls. Emits `closed`
## and frees itself on ui_cancel / Back.

signal closed

const ROWS := [
	["Move", "Left Stick / D-Pad", "WASD"],
	["Dodge (God Hand style)", "Right Stick flick", "T F G H"],
	["Light / Heavy attack", "X / Y", "J / I"],
	["Ki Blast", "Y at range", "I at range"],
	["Jump", "A", "K"],
	["Jump attacks (blast / special too)", "A, then X / Y / LT + Y", "K, then J / I / U + I"],
	["Duck kick", "Right Stick up + Y", "T + I"],
	["Guard (Fwd: high, Back: low)", "B", "L"],
	["Teleport (timed guard)", "B on hit / just before one", "L"],
	["Charge Ki", "LT (hold)", "U"],
	["Special (Fwd: Super 2, Back: Ultimate)", "LT + Y", "U + I"],
	["Throw (break: guard)", "RB", "O"],
	["Taunt (gains ki)", "RT", "Y"],
	["Target / cycle lock", "LB", "Q"],
	["Revive a downed ally (co-op)", "Hold RT near them", "Hold Y near them"],
	["Dash", "L3", "Shift"],
	["Pause", "Start", "Esc"],
]

## "Online" section; %d = Tuning.net.default_port.
const ONLINE_LINES := [
	"Host: open a room from the lobby (Play > Open online). Others pick Join online and type your address.",
	"Your UDP port %d must be reachable. UPnP is tried automatically; if it fails, forward the port on your router, or play over LAN or a VPN such as Tailscale or ZeroTier.",
	"Windows shows a firewall prompt the first time you host: allow it.",
	"The port, your profile name and input delay are in Settings.",
]


var _scroll: ScrollContainer
var _grid: GridContainer
## Scrolled content: the controls grid, then the Online section.
var _content: VBoxContainer
var _col: VBoxContainer
var _panel: PanelContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UiTheme.get_theme()
	var u := UiTheme.tuning()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_panel = PanelContainer.new()
	_col = VBoxContainer.new()
	_panel.add_child(_col)
	_col.add_child(MenuHelpers.title("HOW TO PLAY", &"HeaderLabel"))
	# Only the controls grid scrolls; title, tip and Back stay put. Back keeps
	# focus: ui_up / ui_down, the right stick and the mouse wheel scroll.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col.add_child(_scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", u.how_to_grid_separation.x)
	_grid.add_theme_constant_override("v_separation", u.how_to_grid_separation.y)
	for h in ["Action", "Gamepad", "Keyboard (P1)"]:
		var hl := MenuHelpers.label(h)
		hl.add_theme_color_override("font_color", u.color_orange)
		_grid.add_child(hl)
	for r in ROWS:
		for i in 3:
			var l := MenuHelpers.label(r[i], &"HintLabel" if i > 0 else &"")
			_grid.add_child(l)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(_grid)
	var online := MenuHelpers.label("Online")
	online.add_theme_color_override("font_color", u.color_orange)
	_content.add_child(online)
	for line: String in ONLINE_LINES:
		var l := MenuHelpers.label(line % Tuning.net.default_port if line.contains("%d") else line, &"HintLabel")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content.add_child(l)
	_scroll.add_child(_content)
	var tip := MenuHelpers.label("Land hits to build ki. Read the attack, flick the right stick to slip it, punish!",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_col.add_child(tip)
	var back := MenuHelpers.button("Back", close)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_col.add_child(back)
	add_child(MenuHelpers.centered(_panel))
	resized.connect(_fit)
	_content.minimum_size_changed.connect(_fit)
	_fit()
	back.grab_focus.call_deferred()


## Size the scroll area to the whole grid, or to what is left of the screen
## (minus margins and the panel's fixed parts) when the grid is taller.
func _fit() -> void:
	if _scroll == null:
		return
	var u := UiTheme.tuning()
	var view_h := size.y if size.y > 0.0 else get_viewport_rect().size.y
	var view_w := size.x if size.x > 0.0 else get_viewport_rect().size.x
	_scroll.custom_minimum_size.y = 0.0
	var fixed := _panel.get_combined_minimum_size().y - _scroll.get_combined_minimum_size().y
	var grid_h := _content.get_combined_minimum_size().y
	_scroll.custom_minimum_size.y = clampf(grid_h, 0.0, maxf(view_h - 2.0 * u.how_to_margin.y - fixed, 0.0))
	# Keep the grid's width plus room for the scrollbar, bounded by the screen.
	var bar_w := _scroll.get_v_scroll_bar().get_combined_minimum_size().x
	var panel_extra := _panel.get_combined_minimum_size().x - _col.get_combined_minimum_size().x
	_scroll.custom_minimum_size.x = minf(_grid.get_combined_minimum_size().x + bar_w,
			maxf(view_w - 2.0 * u.how_to_margin.x - panel_extra, 0.0))


## Scroll the controls list by `steps` ui steps (negative = up).
func scroll_by(steps: float) -> void:
	_scroll.scroll_vertical = roundi(_scroll.scroll_vertical + steps * UiTheme.tuning().how_to_scroll_step)


func _process(delta: float) -> void:
	var u := UiTheme.tuning()
	var axis := 0.0
	for device in Input.get_connected_joypads():
		var v := Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y)
		if absf(v) > absf(axis):
			axis = v
	if absf(axis) >= u.how_to_stick_deadzone:
		_scroll.scroll_vertical = roundi(_scroll.scroll_vertical + axis * u.how_to_stick_scroll_speed * delta)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_down", true):
		get_viewport().set_input_as_handled()
		scroll_by(1)
	elif event.is_action_pressed("ui_up", true):
		get_viewport().set_input_as_handled()
		scroll_by(-1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		close()


func close() -> void:
	closed.emit()
	queue_free()
