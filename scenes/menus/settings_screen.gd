class_name SettingsScreen
extends Control
## Settings hub: tabs Graphics / Audio / Controls / Online, switched with
## LB/RB on any pad or Q/E / PageUp/PageDown on a keyboard (or by clicking a
## tab). Each tab is a page (SettingsPage contract; Controls is the
## embedded ControlsScreen) that edits and saves its own settings:
## Settings.video (user://video.cfg), Settings.audio (user://audio.cfg),
## Bindings (user://controls.cfg), Net.settings (user://online.cfg).
##
## The status line shows the focused row's help or the page's last message.
## ui_cancel / Back leaves (main menu, or `closed` as an overlay) unless the
## page still needs the player: rebinding, typing, a prompt, or a staged
## display change (which is applied and confirmed first).
##
## Overlay use (pause menu; works while the tree is paused):
##   var s := SettingsScreen.open_overlay(self, layer, true)
##   s.closed.connect(_on_settings_closed)
## `in_match` locks the Online page's session settings.
##
## Without online play (Net.online_available() false: web) there is no
## Online tab and `online` stays null.

signal closed

const SCENE_PATH := "res://scenes/menus/settings_screen.tscn"
enum Tab { GRAPHICS, AUDIO, CONTROLS, ONLINE }
const HINT := "[LB]/[RB] or Q/E tabs     [A]/[Enter] select     [B]/[Esc] back"

## Back emits `closed` and frees this node instead of going to the main menu.
var as_overlay := false
## Opened during a match (Online page read-only).
var in_match := false
var initial_tab: int = Tab.GRAPHICS

var graphics: GraphicsPage
var audio: AudioPage
var controls: ControlsScreen
## null when this platform has no online play.
var online: OnlinePage
## Pages in tab order.
var pages: Array[Control] = []
var tab_buttons: Array[Button] = []
var current := -1
var status: Label
var _message := ""
var _message_error := false


## Instantiate as an overlay on its own CanvasLayer under `parent`.
static func open_overlay(parent: Node, layer: int = 100, p_in_match := true) -> SettingsScreen:
	var cl := CanvasLayer.new()
	cl.name = "SettingsOverlay"
	cl.layer = layer
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	var s: SettingsScreen = (load(SCENE_PATH) as PackedScene).instantiate()
	s.as_overlay = true
	s.in_match = p_in_match
	cl.add_child(s)
	s.tree_exited.connect(cl.queue_free)
	parent.add_child(cl)
	return s


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var u := UiTheme.tuning()
	MenuHelpers.setup_screen(self)
	if as_overlay:
		var dim := ColorRect.new()
		dim.color = Tuning.hud.pause_dim_color
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(dim)
	else:
		add_child(AnimatedBackground.new())

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", u.settings_separation)
	add_child(col)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = u.settings_margin.x
	col.offset_right = -u.settings_margin.x
	col.offset_top = u.settings_margin.y
	col.offset_bottom = -u.settings_margin.y
	col.add_child(MenuHelpers.title("SETTINGS"))

	graphics = GraphicsPage.new()
	audio = AudioPage.new()
	controls = (load(ControlsScreen.SCENE_PATH) as PackedScene).instantiate()
	controls.embedded = true
	pages = [graphics, audio, controls]
	if Net.online_available():
		online = OnlinePage.new()
		online.locked = in_match
		pages.append(online)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", u.settings_tab_separation)
	bar.add_child(MenuHelpers.label("LB", &"HintLabel"))
	for i in pages.size():
		var b := Button.new()
		b.text = str(pages[i].get("title"))
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", u.settings_tab_font)
		b.pressed.connect(func() -> void: select_tab(i))
		bar.add_child(b)
		tab_buttons.append(b)
	bar.add_child(MenuHelpers.label("RB", &"HintLabel"))
	col.add_child(bar)

	var area := Control.new()
	area.name = "Pages"
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.clip_contents = true
	col.add_child(area)
	for p in pages:
		area.add_child(p)
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		p.visible = false
		if p.has_signal(&"status"):
			p.connect(&"status", _on_page_status)

	status = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(status)
	col.add_child(MenuHelpers.label(HINT, &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))

	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	select_tab(initial_tab)


func page() -> Control:
	return pages[current]


## Show tab `i` (wraps). Stays put while the current page still needs the
## player (e.g. a display change awaiting confirmation).
func select_tab(i: int) -> void:
	i = posmod(i, pages.size())
	if i == current:
		return
	if current >= 0:
		var old := page()
		if old.call(&"is_busy") or old.call(&"flush"):
			return
		old.call(&"on_close")
		old.visible = false
	current = i
	page().visible = true
	var u := UiTheme.tuning()
	for j in tab_buttons.size():
		tab_buttons[j].add_theme_color_override("font_color", u.color_focus if j == i else u.color_text_dim)
	_message = ""
	_refresh_status()
	page().call(&"focus_first")


## Leave the hub, saving every page; waits while a page needs the player.
func back() -> void:
	var p := page()
	if p.call(&"is_busy") or p.call(&"flush"):
		return
	for pg in pages:
		pg.call(&"on_close")
	if as_overlay:
		closed.emit()
		queue_free()
	else:
		Game.goto(Game.SCENE_MAIN_MENU)


func _unhandled_input(event: InputEvent) -> void:
	if current < 0 or page().call(&"is_busy"):
		return
	var dir := tab_direction(event)
	if dir != 0:
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_move")
		select_tab(current + dir)
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		back()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		get_viewport().set_input_as_handled()
		page().call(&"focus_first")


## -1 / +1 for a previous / next tab press (LB/RB on any pad, Q/E or
## PageUp/PageDown), else 0.
static func tab_direction(event: InputEvent) -> int:
	if event is InputEventJoypadButton and event.pressed:
		match (event as InputEventJoypadButton).button_index:
			JOY_BUTTON_LEFT_SHOULDER:
				return -1
			JOY_BUTTON_RIGHT_SHOULDER:
				return 1
	elif event is InputEventKey and event.pressed and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_Q, KEY_PAGEUP:
				return -1
			KEY_E, KEY_PAGEDOWN:
				return 1
	return 0


func _on_page_status(text: String, error: bool) -> void:
	_message = text
	_message_error = error
	_refresh_status()


func _on_focus_changed(_c: Control) -> void:
	if not _message_error:
		_message = ""
	_refresh_status()


func _refresh_status() -> void:
	var u := UiTheme.tuning()
	var text := _message
	if text.is_empty():
		var f := get_viewport().gui_get_focus_owner()
		if f != null and is_ancestor_of(f) and f.has_meta(&"help"):
			text = str(f.get_meta(&"help"))
	status.text = text
	status.add_theme_color_override("font_color", u.color_error if _message_error and not _message.is_empty()
			else u.color_text_dim)
