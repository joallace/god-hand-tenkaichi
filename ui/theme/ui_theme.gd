class_name UiTheme
extends RefCounted
## Shared bold fighting-game Theme, built in code from Tuning.ui.
## Use: `control.theme = UiTheme.get_theme()` on a screen root.
## Type variations: "TitleLabel", "HeaderLabel", "HintLabel", "PanelBox",
## "RowButton".

static var _cached: Theme


static func get_theme() -> Theme:
	if _cached == null:
		_cached = build()
	return _cached


## Drop the cache (e.g. after editing Tuning.ui at runtime).
static func invalidate() -> void:
	_cached = null


static func tuning() -> UiTuning:
	var t: UiTuning = Tuning.ui if Tuning.get("ui") != null else null
	return t if t != null else UiTuning.new()


static func build() -> Theme:
	var u := tuning()
	var th := Theme.new()

	var font := FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = u.font_embolden
	th.default_font = font
	th.default_font_size = u.font_body

	# --- Button ---------------------------------------------------------------
	th.set_stylebox("normal", "Button", _box(u.color_blue_dark, u.color_blue, u.border_width, u))
	th.set_stylebox("hover", "Button", _box(u.color_blue, u.color_orange_light, u.border_width, u))
	var pressed := _box(u.color_orange.darkened(0.35), u.color_focus, u.focus_border_width, u)
	pressed.content_margin_top += 4
	pressed.content_margin_bottom -= 4
	th.set_stylebox("pressed", "Button", pressed)
	th.set_stylebox("hover_pressed", "Button", pressed)
	th.set_stylebox("disabled", "Button", _box(Color(u.color_blue_dark, 0.6), u.color_disabled, u.border_width, u))
	# "focus" is drawn on top of the state box: translucent orange fill + glow.
	var focus := _box(Color(u.color_orange, 0.45), u.color_focus, u.focus_border_width, u)
	focus.expand_margin_left = 6
	focus.expand_margin_right = 6
	focus.expand_margin_top = 4
	focus.expand_margin_bottom = 4
	focus.shadow_color = Color(u.color_orange, 0.8)
	focus.shadow_size = 14
	th.set_stylebox("focus", "Button", focus)
	th.set_font_size("font_size", "Button", u.font_button)
	th.set_constant("outline_size", "Button", u.outline_text)
	th.set_color("font_outline_color", "Button", u.color_outline)
	th.set_color("font_color", "Button", u.color_text)
	th.set_color("font_hover_color", "Button", u.color_orange_light)
	th.set_color("font_focus_color", "Button", u.color_focus)
	th.set_color("font_pressed_color", "Button", u.color_focus)
	th.set_color("font_hover_pressed_color", "Button", u.color_focus)
	th.set_color("font_disabled_color", "Button", u.color_disabled)

	# "RowButton": unskewed full-width list rows (controls screen).
	th.set_type_variation("RowButton", "Button")
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var rb := (th.get_stylebox(st, "Button") as StyleBoxFlat).duplicate() as StyleBoxFlat
		rb.skew = Vector2.ZERO
		rb.expand_margin_left = 0
		rb.expand_margin_right = 0
		rb.shadow_size = 0
		th.set_stylebox(st, "RowButton", rb)

	# --- Labels -----------------------------------------------------------------
	th.set_color("font_color", "Label", u.color_text)
	th.set_color("font_outline_color", "Label", u.color_outline)
	th.set_constant("outline_size", "Label", u.outline_text)
	th.set_font_size("font_size", "Label", u.font_body)

	th.set_type_variation("TitleLabel", "Label")
	th.set_font_size("font_size", "TitleLabel", u.font_title)
	th.set_constant("outline_size", "TitleLabel", u.outline_title)
	th.set_color("font_color", "TitleLabel", u.color_orange_light)
	th.set_color("font_outline_color", "TitleLabel", u.color_blue_dark)
	th.set_color("font_shadow_color", "TitleLabel", Color(0, 0, 0, 0.6))
	th.set_constant("shadow_offset_x", "TitleLabel", 6)
	th.set_constant("shadow_offset_y", "TitleLabel", 8)

	th.set_type_variation("HeaderLabel", "Label")
	th.set_font_size("font_size", "HeaderLabel", u.font_header)
	th.set_constant("outline_size", "HeaderLabel", u.outline_text + 4)
	th.set_color("font_color", "HeaderLabel", u.color_orange)

	th.set_type_variation("HintLabel", "Label")
	th.set_font_size("font_size", "HintLabel", u.font_hint)
	th.set_color("font_color", "HintLabel", u.color_text_dim)
	th.set_constant("outline_size", "HintLabel", maxi(u.outline_text - 3, 2))

	# --- Panels -----------------------------------------------------------------
	var panel := _box(u.color_panel, u.color_orange, u.border_width, u)
	panel.skew = Vector2.ZERO
	panel.set_content_margin_all(20)
	th.set_stylebox("panel", "PanelContainer", panel)
	th.set_type_variation("PanelBox", "PanelContainer")
	var panel_blue := panel.duplicate() as StyleBoxFlat
	panel_blue.border_color = u.color_blue
	th.set_stylebox("panel", "PanelBox", panel_blue)
	th.set_stylebox("panel", "Panel", panel)

	# --- Containers / scroll ------------------------------------------------------
	th.set_constant("separation", "VBoxContainer", u.list_separation)
	th.set_constant("separation", "HBoxContainer", u.list_separation)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = u.color_orange
	grabber.set_corner_radius_all(4)
	th.set_stylebox("grabber", "VScrollBar", grabber)
	th.set_stylebox("grabber_highlight", "VScrollBar", grabber)
	th.set_stylebox("grabber_pressed", "VScrollBar", grabber)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(u.color_blue_dark, 0.7)
	track.content_margin_left = 6
	track.content_margin_right = 6
	th.set_stylebox("scroll", "VScrollBar", track)
	return th


static func _box(bg: Color, border: Color, border_w: int, u: UiTuning) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(border_w)
	b.set_corner_radius_all(u.corner_radius)
	b.skew = Vector2(u.box_skew, 0)
	b.content_margin_left = 28
	b.content_margin_right = 28
	b.content_margin_top = 10
	b.content_margin_bottom = 10
	b.anti_aliasing = true
	return b
