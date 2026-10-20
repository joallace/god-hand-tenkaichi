class_name ConfirmPrompt
extends Control
## Modal yes/no prompt over the current screen (works while the tree is
## paused). Optional countdown: when it runs out the prompt resolves as
## "no" (the safe choice, e.g. revert display settings). ui_cancel = no.
## Focus starts on the safe button and returns to the previously focused
## control when the prompt closes.
##   var p := ConfirmPrompt.open(self, "Keep these display settings?", "Keep", "Revert", 10.0)
##   p.resolved.connect(func(yes: bool) -> void: ...)

signal resolved(accepted: bool)

var message := ""
var yes_text := "Yes"
var no_text := "No"
## Seconds until it resolves as "no" (0 = no countdown).
var countdown := 0.0

var yes_btn: Button
var no_btn: Button
var _label: Label
var _time_left := 0.0
var _prev_focus: Control
var _done := false


static func open(parent: Node, p_message: String, p_yes: String, p_no: String, p_countdown := 0.0) -> ConfirmPrompt:
	var p := ConfirmPrompt.new()
	p.message = p_message
	p.yes_text = p_yes
	p.no_text = p_no
	p.countdown = p_countdown
	parent.add_child(p)
	return p


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	var u := UiTheme.tuning()
	theme = UiTheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_prev_focus = get_viewport().gui_get_focus_owner()
	# Opened from another prompt's answer: return to what that one would.
	var n: Node = _prev_focus
	while n != null:
		if n is ConfirmPrompt:
			_prev_focus = (n as ConfirmPrompt)._prev_focus
			break
		n = n.get_parent()
	_time_left = countdown

	var dim := ColorRect.new()
	dim.color = Tuning.hud.pause_dim_color
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.custom_minimum_size.x = u.confirm_width
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", u.confirm_padding)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, u.confirm_padding)
	margin.add_child(col)
	panel.add_child(margin)

	_label = MenuHelpers.label("", &"", HORIZONTAL_ALIGNMENT_CENTER)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", u.confirm_padding)
	yes_btn = MenuHelpers.button(yes_text, resolve.bind(true))
	no_btn = MenuHelpers.button(no_text, resolve.bind(false))
	for b: Button in [yes_btn, no_btn]:
		b.custom_minimum_size.x = (u.confirm_width - u.confirm_padding * 3) / 2.0
		row.add_child(b)
	yes_btn.focus_neighbor_left = yes_btn.get_path_to(no_btn)
	yes_btn.focus_neighbor_right = yes_btn.get_path_to(no_btn)
	no_btn.focus_neighbor_left = no_btn.get_path_to(yes_btn)
	no_btn.focus_neighbor_right = no_btn.get_path_to(yes_btn)
	for b: Button in [yes_btn, no_btn]:
		b.focus_neighbor_top = NodePath(".")
		b.focus_neighbor_bottom = NodePath(".")
	col.add_child(row)
	add_child(MenuHelpers.centered(panel))
	_refresh()
	no_btn.grab_focus.call_deferred()


func _process(delta: float) -> void:
	if countdown <= 0.0 or _done:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		resolve(false)
		return
	_refresh()


func time_left() -> float:
	return _time_left


func resolve(accepted: bool) -> void:
	if _done:
		return
	_done = true
	# Queued before `resolved` so a prompt opened by the answer keeps focus.
	if is_instance_valid(_prev_focus):
		_prev_focus.grab_focus.call_deferred()
	resolved.emit(accepted)
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	# Modal: nothing behind the prompt sees input while it is open.
	get_viewport().set_input_as_handled()
	if event.is_action_pressed("ui_cancel"):
		Sfx.play(&"ui_back")
		resolve(false)
	elif get_viewport().gui_get_focus_owner() == null and (event.is_action_pressed("ui_left")
			or event.is_action_pressed("ui_right") or event.is_action_pressed("ui_accept")):
		no_btn.grab_focus()


func _refresh() -> void:
	_label.text = message
	if countdown > 0.0:
		_label.text += "\n" + ("Reverting in %d..." % ceili(maxf(_time_left, 0.0)))
