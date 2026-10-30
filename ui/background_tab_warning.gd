class_name BackgroundTabWarning
extends CanvasLayer
## Web, online: a browser throttles a hidden tab, so its peer stops sending
## inputs and the match stalls for everyone. When the page comes back after
## being hidden (or unfocused) during an online session, this banner says so
## for a while. Presentation only: it reads Net.is_online() and never
## touches the session. Net adds one on web; tests drive page_hidden() /
## page_shown() with a clock in msec.

const TEXT := "Keep this tab in front: the match pauses for everyone while it's hidden."
## Above the match HUD and the menus.
const LAYER := 120

var panel: PanelContainer
var _hidden_at := -1
var _left := 0.0


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	var u := UiTheme.tuning()
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.get_theme()
	add_child(root)
	panel = PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = u.background_tab_warning_margin
	var l := MenuHelpers.label(TEXT, &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	l.add_theme_color_override("font_color", u.color_orange_light)
	panel.add_child(l)
	root.add_child(panel)
	panel.visible = false


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			page_hidden(Time.get_ticks_msec())
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			page_shown(Time.get_ticks_msec())


## The page lost focus / was hidden at `now_ms` (only counts while online).
func page_hidden(now_ms: int) -> void:
	if Net.is_online() and _hidden_at < 0:
		_hidden_at = now_ms


## The page is back at `now_ms`: warn if it was away long enough while online.
func page_shown(now_ms: int) -> void:
	if _hidden_at < 0:
		return
	var away := (now_ms - _hidden_at) / 1000.0
	_hidden_at = -1
	if Net.is_online() and away >= UiTheme.tuning().background_tab_min_hidden_seconds:
		show_warning()


func show_warning() -> void:
	_left = UiTheme.tuning().background_tab_warning_seconds
	if panel != null:
		panel.visible = true


func is_showing() -> bool:
	return panel != null and panel.visible


func _process(delta: float) -> void:
	if not is_showing():
		return
	_left -= delta
	if _left <= 0.0 or not Net.is_online():
		panel.visible = false


func _input(event: InputEvent) -> void:
	if is_showing() and event.is_pressed() and not event.is_echo() \
			and (event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton):
		panel.visible = false  # dismissed; the event still reaches the game
