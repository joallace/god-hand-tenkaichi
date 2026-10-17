class_name MenuHelpers
extends RefCounted
## Small builders shared by every menu screen: themed roots, titles, vertical
## button lists with wrap-around focus, option selectors, press feedback.


## Make `root` a full-rect themed screen.
static func setup_screen(root: Control) -> void:
	root.theme = UiTheme.get_theme()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func title(text: String, variation: StringName = &"TitleLabel") -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


static func label(text: String, variation: StringName = &"", align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	if variation != &"":
		l.theme_type_variation = variation
	return l


## A themed Button with press punch feedback. `on_press` may be an invalid
## Callable for disabled placeholders.
static func button(text: String, on_press: Callable = Callable(), disabled := false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = UiTheme.tuning().button_min_size
	b.disabled = disabled
	b.focus_mode = Control.FOCUS_NONE if disabled else Control.FOCUS_ALL
	b.pressed.connect(func() -> void: punch(b))
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b


static func selector(text: String, options: PackedStringArray, index := 0) -> OptionSelector:
	var s := OptionSelector.new()
	s.setup(text, options, index)
	s.custom_minimum_size = UiTheme.tuning().button_min_size
	return s


## VBox of controls with vertical focus neighbours that wrap top<->bottom.
static func vlist(items: Array, center := true) -> VBoxContainer:
	var box := VBoxContainer.new()
	if center:
		box.alignment = BoxContainer.ALIGNMENT_CENTER
	for c in items:
		if center and c is Control:
			(c as Control).size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(c)
	link_vertical(box.get_children())
	return box


## Chain focus neighbours of the focusable controls in `items` (wrapping).
static func link_vertical(items: Array) -> void:
	var f: Array[Control] = []
	for c in items:
		if c is Control and (c as Control).focus_mode != Control.FOCUS_NONE and (c as Control).visible:
			f.append(c)
	for i in f.size():
		var prev := f[posmod(i - 1, f.size())]
		var next := f[posmod(i + 1, f.size())]
		f[i].focus_neighbor_top = f[i].get_path_to(prev)
		f[i].focus_neighbor_bottom = f[i].get_path_to(next)
		f[i].focus_previous = f[i].get_path_to(prev)
		f[i].focus_next = f[i].get_path_to(next)
		# Left/right stay on the same control (selectors use them to cycle).
		f[i].focus_neighbor_left = NodePath(".")
		f[i].focus_neighbor_right = NodePath(".")


## Grab focus on the first focusable control under `node` (deferred-safe).
static func focus_first(node: Node) -> void:
	var c := find_first_focusable(node)
	if c != null:
		c.grab_focus.call_deferred()


static func find_first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child is Control and child.visible:
			var ctl := child as Control
			if ctl.focus_mode == Control.FOCUS_ALL and not (ctl is BaseButton and (ctl as BaseButton).disabled):
				return ctl
			var deeper := find_first_focusable(ctl)
			if deeper != null:
				return deeper
	return null


## Quick scale punch for press feedback.
static func punch(c: Control) -> void:
	if not c.is_inside_tree():
		return
	var u := UiTheme.tuning()
	c.pivot_offset = c.size * 0.5
	var tw := c.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(c, "scale", Vector2.ONE * u.press_punch_scale, u.press_punch_time * 0.4)
	tw.tween_property(c, "scale", Vector2.ONE, u.press_punch_time * 0.6) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Centered container filling the screen with `child` inside.
static func centered(child: Control) -> CenterContainer:
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cc.add_child(child)
	return cc


## CharacterRegistry is loaded dynamically so the menus keep working (with a
## fallback roster) even while gameplay scripts are mid-refactor.
const CHARACTER_REGISTRY_PATH := "res://gameplay/characters/character_registry.gd"
const FALLBACK_CHARACTER := &"brawler"


static func _registry() -> Script:
	var s := load(CHARACTER_REGISTRY_PATH) as Script
	return s if s != null and s.can_instantiate() else null


static func _registry_has(s: Script, method: String) -> bool:
	for m in s.get_script_method_list():
		if m["name"] == method:
			return true
	return false


static func character_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	var s := _registry()
	if s != null and _registry_has(s, "ids"):
		for id in s.call("ids"):
			out.append(StringName(id))
	if out.is_empty():
		out.append(FALLBACK_CHARACTER)
	return out


## Display name for a character id; uses CharacterRegistry.display_name(id)
## when that API exists, else a capitalized id.
static func character_name(id: StringName) -> String:
	var s := _registry()
	if s != null and _registry_has(s, "display_name"):
		return str(s.call("display_name", id))
	return String(id).capitalize()


static func round_time_label(seconds: int) -> String:
	return "∞" if seconds <= 0 else str(seconds)


static func device_label(device_kind: int, device_id: int, slot: int) -> String:
	if device_kind == Bindings.Kind.KEYBOARD:
		return "Keyboard (%s)" % ["WASD layout" if slot == 0 else "Arrows layout"]
	var n := Input.get_joy_name(device_id)
	return n if n != "" else "Gamepad %d" % (device_id + 1)
