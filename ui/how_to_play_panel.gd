class_name HowToPlayPanel
extends Control
## Modal "How to play" overlay listing the default controls. Emits `closed`
## and frees itself on ui_cancel / Back.

signal closed

const ROWS := [
	["Move", "Left Stick / D-Pad", "WASD"],
	["Dodge (God Hand style)", "Right Stick flick", "T F G H"],
	["Light / Heavy attack", "X / Y", "J / I"],
	["Ki Blast", "B", "L"],
	["Jump", "A", "K"],
	["Guard", "RB", "E"],
	["Charge Ki", "LB (hold)", "Q"],
	["Dash", "L3", "Shift"],
	["Teleport (on hit / vanish out of hitstun)", "LT", "O"],
	["Special (5 ki bars)", "RT / Back+RT / Fwd+RT", "U"],
	["Pause", "Start", "Esc"],
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UiTheme.get_theme()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	var col := VBoxContainer.new()
	panel.add_child(col)
	col.add_child(MenuHelpers.title("HOW TO PLAY", &"HeaderLabel"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 6)
	for h in ["Action", "Gamepad", "Keyboard (P1)"]:
		var hl := MenuHelpers.label(h)
		hl.add_theme_color_override("font_color", UiTheme.tuning().color_orange)
		grid.add_child(hl)
	for r in ROWS:
		for i in 3:
			var l := MenuHelpers.label(r[i], &"HintLabel" if i > 0 else &"")
			grid.add_child(l)
	col.add_child(grid)
	col.add_child(MenuHelpers.label("Land hits to build ki. Read the attack, flick the right stick to slip it, punish!",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))
	var back := MenuHelpers.button("Back", close)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(back)
	add_child(MenuHelpers.centered(panel))
	back.grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		close()


func close() -> void:
	closed.emit()
	queue_free()
