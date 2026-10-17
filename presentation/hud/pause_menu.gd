class_name PauseMenu
extends CanvasLayer
## In-match pause overlay. Opens on MatchDirector.pause_requested: sets
## director.paused (and pauses the tree so visuals freeze too). Navigable
## with any joypad / keyboard through the default ui_* actions.
## Resume: Resume button, ui_cancel, or pressing any local player's Pause
## binding again (the director doesn't poll inputs while paused, so this menu
## polls the bindings itself).

const LAYER := 50
const UI_THEME_PATH := "res://ui/theme/ui_theme.gd"

var director: MatchDirector
var is_open := false

var _dim: ColorRect
var _panel: Control
var _subtitle: Label
var _buttons: Array[Button] = []
var _controls_overlay: Node
var _pause_held: Dictionary = {}  # slot -> bool (previous frame)


func _init() -> void:
	name = "PauseMenu"
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(p_director: MatchDirector) -> void:
	director = p_director
	director.pause_requested.connect(open)
	_build()
	visible = false


func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var th := _load_theme()
	if th != null:
		root.theme = th

	_dim = ColorRect.new()
	_dim.color = Tuning.hud.pause_dim_color
	root.add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	root.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = center

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	var ls := LabelSettings.new()
	ls.font_size = 72
	ls.font_color = Tuning.hud.announce_color
	ls.outline_size = 12
	ls.outline_color = Tuning.hud.outline_color
	title.label_settings = ls
	box.add_child(title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_subtitle)

	_add_button(box, "Resume", resume)
	if ResourceLoader.exists(Game.SCENE_CONTROLS):
		_add_button(box, "Controls", _open_controls)
	_add_button(box, "Quit to Menu", _quit)

	for i in _buttons.size():
		var b := _buttons[i]
		var prev := _buttons[(i - 1 + _buttons.size()) % _buttons.size()]
		var next := _buttons[(i + 1) % _buttons.size()]
		b.focus_neighbor_top = b.get_path_to(prev)
		b.focus_neighbor_bottom = b.get_path_to(next)
		b.focus_previous = b.focus_neighbor_top
		b.focus_next = b.focus_neighbor_bottom


func _add_button(box: Container, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.name = text.replace(" ", "")
	b.text = text
	b.custom_minimum_size = Vector2(380, 56)
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(cb)
	box.add_child(b)
	_buttons.append(b)


func _load_theme() -> Theme:
	if not ResourceLoader.exists(UI_THEME_PATH):
		return null
	var script: Script = load(UI_THEME_PATH)
	var th: Variant = script.call("get_theme") if script != null else null
	return th as Theme if th is Theme else null


# --- open / close ---------------------------------------------------------------

func open(slot: int) -> void:
	if is_open or director == null:
		return
	is_open = true
	director.paused = true
	get_tree().paused = true
	visible = true
	_subtitle.text = "P%d paused" % (slot + 1)
	# The press that opened us must not immediately resume.
	_pause_held = _sample_pause_buttons()
	_buttons[0].grab_focus.call_deferred()


func resume() -> void:
	if not is_open:
		return
	_close_controls()
	is_open = false
	visible = false
	get_tree().paused = false
	if director != null:
		director.paused = false


func _quit() -> void:
	is_open = false
	Game.goto(Game.SCENE_MAIN_MENU)


func _open_controls() -> void:
	var packed := load(Game.SCENE_CONTROLS) as PackedScene
	if packed == null:
		return
	var cs := packed.instantiate()
	if "as_overlay" in cs:
		cs.set("as_overlay", true)
	cs.process_mode = Node.PROCESS_MODE_ALWAYS
	var cl := CanvasLayer.new()
	cl.name = "ControlsOverlay"
	cl.layer = LAYER + 1
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	cl.add_child(cs)
	add_child(cl)
	_controls_overlay = cl
	if cs.has_signal(&"closed"):
		cs.connect(&"closed", _on_controls_closed)
	cs.tree_exited.connect(_on_controls_closed)
	_panel.visible = false


func _on_controls_closed() -> void:
	if _controls_overlay != null and is_instance_valid(_controls_overlay):
		_controls_overlay.queue_free()
	_controls_overlay = null
	_panel.visible = true
	if is_open:
		_pause_held = _sample_pause_buttons()
		_buttons[0].grab_focus.call_deferred()


func _close_controls() -> void:
	if _controls_overlay != null and is_instance_valid(_controls_overlay):
		_controls_overlay.queue_free()
	_controls_overlay = null
	_panel.visible = true


func _controls_open() -> bool:
	return _controls_overlay != null and is_instance_valid(_controls_overlay)


# --- input ---------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not is_open or _controls_open():
		return
	var now := _sample_pause_buttons()
	for slot: int in now:
		if now[slot] and not _pause_held.get(slot, false):
			resume()
			return
	_pause_held = now


func _unhandled_input(event: InputEvent) -> void:
	if not is_open or _controls_open():
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		resume()


## slot -> is that local player's Pause binding held right now.
func _sample_pause_buttons() -> Dictionary:
	var out := {}
	if director == null or director.config == null:
		return out
	for p in director.config.players:
		if p.input_kind != PlayerSlotConfig.InputKind.LOCAL:
			continue
		var b: Dictionary = Bindings.get_binding(p.slot, p.device_kind, "PAUSE")
		out[p.slot] = Bindings.is_binding_active(b, p.device_id, 0.5)
	return out
