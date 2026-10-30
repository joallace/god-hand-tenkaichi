class_name JoinOnlineScreen
extends Control
## Join online (SPEC_ONLINE.md §10.4, docs/web_online.md). Two ways in, each
## shown only where the platform has it (PlatformCaps):
## - Room code (`room_codes()`, first): a code field (case-insensitive,
##   spaces/dashes ignored; an invite link with `room=` pasted works too)
##   and Join. Codes expire, so they are not kept in recent hosts.
## - Direct IP (`direct_ip()`, desktop): an address field (IP:PORT, hostname
##   or [IPv6]:PORT; the default port when omitted), Connect, and the recent
##   hosts list (Net.settings.recent_hosts: press a row to connect, its "x" /
##   Delete / pad X removes it).
## Either field takes either kind of text (Net.parse_join_text decides).
## A status line shows progress and errors (a room-code join's failure shows
## the transport's own reason). Net.join_succeeded goes to the lobby as a
## guest. Back while connecting cancels the attempt; otherwise it leaves to
## the main menu.
##
## `pending_code` (set before Game.goto: a web invite link at boot) fills
## the code field and joins at once.

static var pending_code: String = ""

var code_edit: LineEdit
var join_btn: Button
var address_edit: LineEdit
var connect_btn: Button
var back_btn: Button
var status: Label
var connecting := false

var _code_row: HBoxContainer
var _addr_row: HBoxContainer
## Recent hosts header + list (direct IP only).
var _recent_header: Label
var _recent_panel: PanelContainer
var _recent_box: VBoxContainer
var _recent_scroll: ScrollContainer
## Recent-host row buttons, in list order (each has meta "address").
var _rows: Array[Button] = []


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var codes := PlatformCaps.room_codes()
	var direct := PlatformCaps.direct_ip()

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", u.online_separation)
	col.add_child(MenuHelpers.title("JOIN ONLINE"))

	_code_row = HBoxContainer.new()
	_code_row.alignment = BoxContainer.ALIGNMENT_CENTER
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "Room code (e.g. K7QX2M) or invite link"
	code_edit.custom_minimum_size = Vector2(u.online_field_width, u.button_min_size.y)
	code_edit.text_submitted.connect(func(t: String) -> void: connect_to(t))
	_code_row.add_child(code_edit)
	join_btn = MenuHelpers.button("Join", func() -> void: connect_to(code_edit.text))
	join_btn.custom_minimum_size.x = 0.0
	_code_row.add_child(join_btn)
	_code_row.visible = codes
	col.add_child(_code_row)

	_addr_row = HBoxContainer.new()
	_addr_row.alignment = BoxContainer.ALIGNMENT_CENTER
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "IP:PORT, hostname or [IPv6]:PORT"
	address_edit.custom_minimum_size = Vector2(u.online_field_width, u.button_min_size.y)
	address_edit.text_submitted.connect(func(t: String) -> void: connect_to(t))
	_addr_row.add_child(address_edit)
	connect_btn = MenuHelpers.button("Connect", func() -> void: connect_to(address_edit.text))
	connect_btn.custom_minimum_size.x = 0.0
	_addr_row.add_child(connect_btn)
	_addr_row.visible = direct
	col.add_child(_addr_row)

	status = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(status)

	_recent_header = MenuHelpers.label("Recent hosts", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_recent_header.visible = direct
	col.add_child(_recent_header)
	_recent_panel = PanelContainer.new()
	_recent_panel.theme_type_variation = &"PanelBox"
	_recent_scroll = ScrollContainer.new()
	_recent_scroll.follow_focus = true
	_recent_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_recent_panel.add_child(_recent_scroll)
	_recent_box = VBoxContainer.new()
	_recent_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent_scroll.add_child(_recent_box)
	_recent_panel.visible = direct
	col.add_child(_recent_panel)

	back_btn = MenuHelpers.button("Back", back)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(back_btn)
	col.add_child(MenuHelpers.label(("[A]/[Enter] connect     [X]/[Del] forget host     [B]/[Esc] back" if direct
			else "[A]/[Enter] join     [B]/[Esc] back"), &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))
	add_child(MenuHelpers.centered(col))

	Net.join_succeeded.connect(_on_join_succeeded)
	Net.join_failed.connect(_on_join_failed)
	rebuild_recent()
	_set_status(_idle_text())
	first_field().grab_focus.call_deferred()
	if not pending_code.is_empty():
		var code := pending_code
		pending_code = ""
		code_edit.text = code
		connect_to(code)


func _exit_tree() -> void:
	if Net.join_succeeded.is_connected(_on_join_succeeded):
		Net.join_succeeded.disconnect(_on_join_succeeded)
	if Net.join_failed.is_connected(_on_join_failed):
		Net.join_failed.disconnect(_on_join_failed)


## The field that gets focus first: the room code where codes exist.
func first_field() -> LineEdit:
	return code_edit if PlatformCaps.room_codes() or not PlatformCaps.direct_ip() else address_edit


func _idle_text() -> String:
	var codes := PlatformCaps.room_codes()
	if not PlatformCaps.direct_ip():
		return "Enter the room code your host shared"
	if codes:
		return "Enter a room code, or the host's address (port %d if omitted)" % Tuning.net.default_port
	return "Enter the host's address (port %d if omitted)" % Tuning.net.default_port


## Rebuild the recent hosts rows from Net.settings; then focus row
## `focus_index` (clamped; Back when the list is empty), -1 = leave focus.
## Without direct IP the list stays empty (and hidden).
func rebuild_recent(focus_index: int = -1) -> void:
	var u := UiTheme.tuning()
	for c in _recent_box.get_children():
		_recent_box.remove_child(c)
		c.queue_free()
	_rows.clear()
	var deletes: Array[Button] = []
	var hosts: Array[Dictionary] = Net.settings.recent_hosts if PlatformCaps.direct_ip() else ([] as Array[Dictionary])
	for h: Dictionary in hosts:
		var address: String = h["address"]
		var row := HBoxContainer.new()
		var b := Button.new()
		b.theme_type_variation = &"RowButton"
		b.custom_minimum_size = Vector2(u.online_field_width, u.online_recent_row_height)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var host_name: String = h.get("name", "")
		b.text = "%s   %s   %s" % [host_name if not host_name.is_empty() else "?", address, h.get("date", "")]
		b.set_meta("address", address)
		b.pressed.connect(func() -> void:
			MenuHelpers.punch(b)
			Sfx.play(&"ui_confirm")
			address_edit.text = address
			connect_to(address))
		b.gui_input.connect(_on_row_input.bind(address))
		row.add_child(b)
		var x := MenuHelpers.button("x", forget.bind(address))
		x.custom_minimum_size = u.online_delete_button_size
		row.add_child(x)
		_recent_box.add_child(row)
		_rows.append(b)
		deletes.append(x)
	if _rows.is_empty():
		_recent_box.add_child(MenuHelpers.label("No recent hosts yet", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER))
	_relink_focus(deletes)
	_fit_recent()
	if focus_index >= 0:
		var to: Control = _rows[mini(focus_index, _rows.size() - 1)] if not _rows.is_empty() else back_btn
		to.grab_focus()


func recent_rows() -> Array[Button]:
	return _rows


func _relink_focus(deletes: Array[Button]) -> void:
	var chain: Array = []
	if _code_row.visible:
		chain.append_array([code_edit, join_btn])
	if _addr_row.visible:
		chain.append_array([address_edit, connect_btn])
	chain.append_array(_rows)
	chain.append(back_btn)
	MenuHelpers.link_vertical(chain)
	# Field <-> button sideways would fight caret movement: each button is
	# below its field in the chain instead. Each row's "x" sits to its right.
	for i in _rows.size():
		var b := _rows[i]
		var x := deletes[i]
		b.focus_neighbor_right = b.get_path_to(x)
		x.focus_neighbor_left = x.get_path_to(b)
		x.focus_neighbor_right = NodePath(".")
		x.focus_neighbor_top = x.get_path_to(b.get_node(b.focus_neighbor_top))
		x.focus_neighbor_bottom = x.get_path_to(b.get_node(b.focus_neighbor_bottom))


## Show the whole list, up to online_recent_max_height (then it scrolls).
func _fit_recent() -> void:
	var h := _recent_box.get_combined_minimum_size().y
	_recent_scroll.custom_minimum_size = Vector2(_recent_box.get_combined_minimum_size().x,
			minf(h, UiTheme.tuning().online_recent_max_height))


func _on_row_input(event: InputEvent, address: String) -> void:
	if (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_DELETE) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_X):
		get_viewport().set_input_as_handled()
		forget(address)


## Remove a recent host and save.
func forget(address: String) -> void:
	var at := -1
	for i in _rows.size():
		if _rows[i].get_meta("address") == address:
			at = i
	Sfx.play(&"ui_back")
	Net.settings.remove_recent_host(address)
	Net.settings.save()
	rebuild_recent(maxi(at, 0))


## Validate `text` (a room code, an invite link or an address) and start
## joining. Returns whether a connection attempt started (bad text only
## shows the error).
func connect_to(text: String) -> bool:
	var p := Net.parse_join_text(text)
	var kind: String = p["kind"]
	if kind == "address" and not PlatformCaps.direct_ip():
		kind = "invalid"
		p["error"] = "not a room code"
	if kind == "code" and not PlatformCaps.room_codes():
		if PlatformCaps.direct_ip():
			kind = "address"  # a 6-letter host name ("server")
		else:
			kind = "invalid"
			p["error"] = "room codes aren't available here"
	if kind == "code" and Net.signaling_url().is_empty():
		_set_status("No room server set (Settings > Online > Signaling server)", true)
		return false
	if kind == "invalid":
		var what := "room code" if not PlatformCaps.direct_ip() else (
				"room code or address" if PlatformCaps.room_codes() else "address")
		_set_status("Invalid %s: %s" % [what, p["error"]] if not text.strip_edges().is_empty()
				else "Enter %s %s" % ["an" if what == "address" else "a", what], true)
		return false
	var err := Net.join(text, kind == "address")
	if err != OK:
		_set_status("Could not resolve %s" % text.strip_edges() if err == ERR_CANT_RESOLVE \
				else "Could not connect (%s)" % error_string(err), true)
		return false
	connecting = true
	join_btn.disabled = true
	connect_btn.disabled = true
	_set_status("Joining room %s…" % p["code"] if kind == "code" else "Connecting to %s…" % text.strip_edges())
	return true


## Abort a connection attempt in progress.
func cancel_connect() -> void:
	if not connecting:
		return
	Net.leave()
	connecting = false
	join_btn.disabled = false
	connect_btn.disabled = false
	_set_status("Cancelled")


func _on_join_succeeded() -> void:
	connecting = false
	Game.goto(Game.SCENE_LOBBY)


func _on_join_failed(_reason: int, text: String) -> void:
	connecting = false
	join_btn.disabled = false
	connect_btn.disabled = false
	_set_status(text if not text.is_empty() else Net.CONNECT_FAILED_TEXT, true)


func _set_status(text: String, error := false) -> void:
	var u := UiTheme.tuning()
	status.text = text
	status.add_theme_color_override("font_color", u.color_error if error else u.color_text_dim)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Sfx.play(&"ui_back")
		back()
	elif get_viewport().gui_get_focus_owner() == null and (
			event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		get_viewport().set_input_as_handled()
		first_field().grab_focus()


## Back: cancels a connection attempt in progress, else leaves to the menu.
func back() -> void:
	if connecting:
		cancel_connect()
		return
	Net.leave()
	Game.goto(Game.SCENE_MAIN_MENU)
