class_name Lobby
extends Control
## Unified lobby (SPEC_ONLINE.md §10.2), local and online. Each physical
## device claims a slot, picks a character and readies up; when every slot is
## ready a MatchConfig is built and the match starts. The data and rules live
## in a LobbyModel (`model`); this screen maps devices to commands and draws it.
##
## Input is read per *device* in _input (event.device), not through global
## ui_* actions, so two pads never steer the same slot.
##
## Gamepad (unjoined): START or A joins the next free slot. B with nobody
##   joined -> main menu (leaving the room online).
## Gamepad (joined):   D-pad / left stick up-down picks a row, left-right
##   changes it; A/START = ready; B = un-ready, then leave.
## Keyboard: ENTER joins a keyboard player into the next free slot; that
##   player's number on this machine picks the Bindings keyboard layout
##   (first = A/WASD, second = B/arrows+numpad). Joined keyboard players
##   navigate with their layout's MOVE keys, ready with their LIGHT or JUMP key
##   (or ENTER once all slots are filled) and back out with their PAUSE key (or
##   ESC). While only one keyboard player is joined, arrow keys also navigate.
## Room (any device): Y / TAB = Open online (local), Close room (host) or
##   Leave (guest); X / C = copy the room address (host). Without online
##   play (Net.online_available() false: web) the room bar is hidden and
##   these keys do nothing.
##
## Local: `model` is this screen's own; the MODE row switches Versus / Versus
##   CPU / Co-op (see LobbyModel). The match starts after
##   UiTheme join_start_delay seconds of everyone ready.
## Online: `model` is Net.room.model. The host applies commands directly; a
##   guest's commands go to the host (OnlineRoom.request) and the screen
##   redraws on every state broadcast. The host's countdown
##   (Tuning.net.lobby_countdown_frames) starts the match on every peer.
## Team versus and co-op have up to four player slots: the panels then stack
##   two per column either side of the settings panel (compact fonts); in
##   co-op with the CPU ally on online, the place it takes
##   (model.human_capacity()) shows the ally. Team versus: each panel shows
##   its team (the player's TEAM row); the settings panel's Seat rows edit
##   the marked slot (CPU in an empty one, its team, a CPU's fighter / level).
## Couch + online: every local device joins its own slot (up to
##   Tuning.net.max_local_players_online), each sending its own request.

## Emitted with the finished config right before a local match starts.
signal match_requested(config: MatchConfig)

const Cmd := LobbyModel.Cmd
const Row := LobbyModel.Row
const SlotType := LobbyModel.SlotType
const SlotState := LobbyModel.SlotState
## Rows that edit the slot under model.seat.
const SEAT_ROWS: Array[int] = [Row.SEAT, Row.SEAT_TYPE, Row.SEAT_TEAM, Row.CPU_CHARACTER, Row.CPU_LEVEL]

## Set before Game.goto(Game.SCENE_LOBBY) to choose the local mode.
static var pending_mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS

var model: LobbyModel
## Tests set this false to inspect match_requested without changing scene.
var auto_start: bool = true
## The rows' slot list (model.slots).
var slots: Array[LobbyModel.Slot]:
	get:
		return model.slots

var _local_model: LobbyModel
var _countdown := 0.0
var _started := false
var _stick_dir: Dictionary = {}  # device -> Vector2i
var _blink := 0.0
## Text shown under the top bar for a while (port in use, copied...).
var _notice := ""

# UI refs
var _ui: Array[Dictionary] = []
var _panel_row: HBoxContainer
var _settings_header: Label
var _cpu_level_label: Label
var _cpu_blurb_label: Label
var _status_label: Label
var _room_label: Label
var _room_button: Button
var _copy_button: Button
var _row_labels: Dictionary = {}  # Row -> Label, every row in the settings panel
## Co-op rows only (tests read their text).
var _coop_labels: Dictionary = {}
var _settings_scroll: ScrollContainer
## Slot whose cursor moved last (the settings list follows it).
var _last_cursor_slot := -1


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	_local_model = LobbyModel.new(pending_mode)
	_local_model.restore()
	model = Net.room.model if Net.room != null else _local_model
	_build_ui()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_watch_room()
	_refresh()


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.disconnect(_on_joy_connection_changed)


func is_online() -> bool:
	return Net.room != null


func is_coop() -> bool:
	return model.is_coop()


func rows() -> Array[int]:
	return model.rows()


func cpu_slot() -> int:
	return model.cpu_target()


func all_ready() -> bool:
	return model.all_ready()


func nobody_joined() -> bool:
	return model.nobody_joined()


func build_config() -> MatchConfig:
	return model.build_config(randi())


## Empty human slots drawn as the CPU ally: online co-op with the ally on
## leaves model.human_capacity() places for humans; the last empty slots
## stand for the ally's place.
func ally_slots() -> Array[int]:
	var out: Array[int] = []
	var humans := 0
	for s in slots:
		if s.type == SlotType.HUMAN:
			humans += 1
	var extra := humans - model.human_capacity()
	for i in range(slots.size() - 1, -1, -1):
		if out.size() >= extra:
			break
		if slots[i].type == SlotType.HUMAN and slots[i].state == SlotState.EMPTY:
			out.append(i)
	return out


# --- Room ------------------------------------------------------------------------

func _watch_room() -> void:
	if Net.room == null:
		return
	if not Net.room.changed.is_connected(_on_room_changed):
		Net.room.changed.connect(_on_room_changed)


func _on_room_changed() -> void:
	if Net.room == null:
		return
	if Net.room.phase != OnlineRoom.Phase.LOBBY:
		_started = true
	_refresh()


## Y / TAB: open a room (local), close it (host) or leave it (guest).
func room_action() -> void:
	if not Net.online_available():
		return
	if not is_online():
		open_online()
	elif Net.is_host():
		close_room()
	else:
		_back_to_menu()


## Host a room; the first local player keeps their slot and pick.
func open_online() -> Error:
	var err := Net.host()
	if err != OK:
		_notice = "Port %d is in use" % Net.settings.host_port() if err == ERR_CANT_CREATE \
			else "Could not open the room (error %d)" % err
		Sfx.play(&"ui_back")
		_refresh()
		return err
	var keep: LobbyModel.Slot = null
	for s in _local_model.slots:
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY \
				and (keep == null or s.join_order < keep.join_order):
			keep = s
	model = Net.room.model
	model.carry_rules_from(_local_model)
	_watch_room()
	if keep != null:
		Net.room.join_local(keep.device_kind, keep.device_id)
		var mine := Net.room.my_slots()
		if not mine.is_empty():
			model.slots[mine[0]].char_index = keep.char_index
	Net.room.publish()
	_notice = ""
	Sfx.play(&"ui_confirm")
	_rebuild_panels()
	_refresh()
	return OK


## Host: close the room and go back to the local lobby.
func close_room() -> void:
	Net.leave()
	model = _local_model
	for s in model.slots:
		if s.state == SlotState.READY and s.type == SlotType.HUMAN:
			s.state = SlotState.JOINED
	_started = false
	Sfx.play(&"ui_back")
	_rebuild_panels()
	_refresh()


func copy_address() -> void:
	var a := _host_addresses()
	if a.is_empty():
		return
	DisplayServer.clipboard_set(a[0])
	_notice = "Copied %s" % a[0]
	_refresh()


## "ip:port" strings worth sharing: the UPnP public address first.
func _host_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	if not Net.is_host():
		return out
	var port := Net.settings.host_port()
	if Net.upnp.status == UpnpHelper.Status.MAPPED and Net.upnp.external_ip != "":
		out.append(_with_port(Net.upnp.external_ip, port))
	for a in UpnpHelper.local_addresses():
		out.append(_with_port(a, port))
	return out


static func _with_port(ip: String, port: int) -> String:
	return ("[%s]:%d" if ip.contains(":") else "%s:%d") % [ip, port]


# --- Input ---------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _started:
		return
	if event is InputEventJoypadButton:
		if event.pressed:
			_on_pad_button(event)
	elif event is InputEventJoypadMotion:
		_on_pad_motion(event)
	elif event is InputEventKey:
		if event.pressed and not event.echo:
			_on_key(event)
	else:
		return
	get_viewport().set_input_as_handled()


func _on_pad_button(e: InputEventJoypadButton) -> void:
	match e.button_index:
		JOY_BUTTON_Y:
			room_action()
			return
		JOY_BUTTON_X:
			copy_address()
			return
	var idx := slot_for_device(Bindings.Kind.PAD, e.device)
	if idx < 0:
		match e.button_index:
			JOY_BUTTON_START, JOY_BUTTON_A:
				join(Bindings.Kind.PAD, e.device)
			JOY_BUTTON_B, JOY_BUTTON_BACK:
				if local_slots().is_empty():
					_back_to_menu()
		return
	match e.button_index:
		JOY_BUTTON_A, JOY_BUTTON_START:
			_command(idx, Cmd.CONFIRM)
		JOY_BUTTON_B, JOY_BUTTON_BACK:
			_command(idx, Cmd.BACK)
		JOY_BUTTON_DPAD_UP:
			_command(idx, Cmd.UP)
		JOY_BUTTON_DPAD_DOWN:
			_command(idx, Cmd.DOWN)
		JOY_BUTTON_DPAD_LEFT:
			_command(idx, Cmd.LEFT)
		JOY_BUTTON_DPAD_RIGHT:
			_command(idx, Cmd.RIGHT)


func _on_pad_motion(e: InputEventJoypadMotion) -> void:
	if e.axis != JOY_AXIS_LEFT_X and e.axis != JOY_AXIS_LEFT_Y:
		return
	var idx := slot_for_device(Bindings.Kind.PAD, e.device)
	if idx < 0:
		return
	var th := UiTheme.tuning().stick_nav_threshold
	var v := Vector2(Input.get_joy_axis(e.device, JOY_AXIS_LEFT_X), Input.get_joy_axis(e.device, JOY_AXIS_LEFT_Y))
	if e.axis == JOY_AXIS_LEFT_X:
		v.x = e.axis_value
	else:
		v.y = e.axis_value
	var dir := Vector2i.ZERO
	if absf(v.x) >= th and absf(v.x) >= absf(v.y):
		dir.x = signi(roundi(signf(v.x)))
	elif absf(v.y) >= th:
		dir.y = signi(roundi(signf(v.y)))
	var prev: Vector2i = _stick_dir.get(e.device, Vector2i.ZERO)
	if dir == prev:
		return
	_stick_dir[e.device] = dir
	if dir.x < 0:
		_command(idx, Cmd.LEFT)
	elif dir.x > 0:
		_command(idx, Cmd.RIGHT)
	elif dir.y < 0:
		_command(idx, Cmd.UP)
	elif dir.y > 0:
		_command(idx, Cmd.DOWN)


const _KEY_LAYOUT_CMDS := {
	"MOVE_FORWARD": Cmd.UP, "MOVE_BACK": Cmd.DOWN,
	"MOVE_LEFT": Cmd.LEFT, "MOVE_RIGHT": Cmd.RIGHT,
	"LIGHT": Cmd.CONFIRM, "JUMP": Cmd.CONFIRM, "PAUSE": Cmd.BACK,
}


func _on_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_TAB:
			room_action()
			return
		KEY_C:
			if Net.is_host():
				copy_address()
				return
	var b := Bindings.binding_from_event(e, Bindings.Kind.KEYBOARD)
	if b.is_empty():
		return
	var code: int = b["i"]
	var kb := keyboard_slots()
	# 1) Per-layout keys of each joined keyboard player.
	for idx in kb:
		for action in _KEY_LAYOUT_CMDS:
			if Bindings.get_binding(binding_slot(idx), Bindings.Kind.KEYBOARD, action) == b:
				_command(idx, _KEY_LAYOUT_CMDS[action])
				return
	# 2) Generic keys.
	match code:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if _can_join_more() and kb.size() < Bindings.SLOT_COUNT:
				join(Bindings.Kind.KEYBOARD, -1)
			else:
				for idx in kb:
					if slots[idx].state == SlotState.JOINED:
						_command(idx, Cmd.CONFIRM)
						return
		KEY_ESCAPE, KEY_BACKSPACE:
			if not kb.is_empty():
				var last := kb[0]
				for idx in kb:
					if slots[idx].join_order > slots[last].join_order:
						last = idx
				_command(last, Cmd.BACK)
			elif local_slots().is_empty():
				_back_to_menu()
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
			if kb.size() == 1:
				var cmd: int = {KEY_UP: Cmd.UP, KEY_DOWN: Cmd.DOWN, KEY_LEFT: Cmd.LEFT, KEY_RIGHT: Cmd.RIGHT}[code]
				_command(kb[0], cmd)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if not connected:
		var idx := slot_for_device(Bindings.Kind.PAD, device)
		if idx >= 0:
			leave(idx)
	_stick_dir.erase(device)
	_refresh()


# --- Slot logic ----------------------------------------------------------------

## Slot of a joined pad on this machine (-1: none; the keyboard may own
## several slots, so it always gets -1).
func slot_for_device(kind: int, device: int) -> int:
	if kind == Bindings.Kind.KEYBOARD:
		return -1
	if is_online():
		return Net.room.slot_of_device(kind, device)
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY \
				and s.device_kind == kind and s.device_id == device:
			return i
	return -1


## Joined slots played on this machine.
func local_slots() -> Array[int]:
	if is_online():
		var out: Array[int] = []
		for slot: int in Net.room.local_devices:
			if slot in Net.room.my_slots():
				out.append(slot)
		out.sort()
		return out
	var all: Array[int] = []
	for i in slots.size():
		if slots[i].type == SlotType.HUMAN and slots[i].state != SlotState.EMPTY:
			all.append(i)
	return all


func keyboard_slots() -> Array[int]:
	var out: Array[int] = []
	for i in local_slots():
		if _device_kind(i) == Bindings.Kind.KEYBOARD:
			out.append(i)
	return out


## Keyboard layout / bindings profile of a local slot, as the match will
## use it (MatchConfig.binding_profile): keyboard players by their order on
## this machine, pads by player number (a guest in slot 2 uses layout A).
func binding_slot(idx: int) -> int:
	var mine := local_slots()
	var at := mine.find(idx)
	if at < 0:
		return 0
	return Bindings.profile_for(mine.map(func(i: int) -> int: return _device_kind(i)), at)


func _device_kind(idx: int) -> int:
	if is_online():
		var d: Array = Net.room.local_devices.get(idx, [Bindings.Kind.PAD, -1])
		return d[0]
	return slots[idx].device_kind


func _device_id(idx: int) -> int:
	if is_online():
		var d: Array = Net.room.local_devices.get(idx, [Bindings.Kind.PAD, -1])
		return d[1]
	return slots[idx].device_id


func first_free_slot() -> int:
	return model.first_free_slot()


func _can_join_more() -> bool:
	if model.first_free_slot() < 0:
		return false
	return not is_online() or local_slots().size() < Tuning.net.max_local_players_online


## Claim the next free HUMAN slot for a device. Returns the slot (online: -1,
## the host answers with the next state) or -1.
func join(kind: int, device: int) -> int:
	if kind == Bindings.Kind.PAD and (slot_for_device(kind, device) >= 0
			or (is_online() and Net.room.is_pending(kind, device))):
		return -1
	if not _can_join_more() or (kind == Bindings.Kind.KEYBOARD and keyboard_slots().size() >= Bindings.SLOT_COUNT):
		return -1
	Sfx.play(&"ui_confirm")
	if is_online():
		Net.room.join_local(kind, device)
		var mine := slot_for_device(kind, device) if kind == Bindings.Kind.PAD else _last(local_slots())
		_punch_panel(mine)
		_refresh()
		return mine
	var idx := model.join(kind, device)
	_punch_panel(idx)
	_refresh()
	return idx


static func _last(a: Array[int]) -> int:
	return a[-1] if not a.is_empty() else -1


func leave(idx: int) -> void:
	if is_online():
		if slots[idx].state == SlotState.READY:
			_send(idx, Cmd.BACK)
		_send(idx, Cmd.BACK)
	else:
		model.leave(idx)
	Sfx.play(&"ui_back")
	_refresh()


func _command(idx: int, cmd: int) -> void:
	if idx < 0 or idx >= slots.size():
		return
	if cmd == Cmd.UP or cmd == Cmd.DOWN:
		_last_cursor_slot = idx
	if is_online():
		_play_for(_predict(idx, cmd), idx)
		_send(idx, cmd)
	else:
		_play_for(model.command(idx, cmd), idx)
	_refresh()


func _send(idx: int, cmd: int) -> void:
	Net.room.request({"op": OnlineRoom.OP_CMD, "slot": idx, "cmd": cmd})


## Online: the event a command will cause (for instant feedback sounds).
func _predict(idx: int, cmd: int) -> StringName:
	var s := slots[idx]
	if s.state == SlotState.READY:
		return LobbyModel.EV_UNREADY if cmd == Cmd.BACK else LobbyModel.EV_NONE
	match cmd:
		Cmd.CONFIRM:
			return LobbyModel.EV_READY
		Cmd.BACK:
			return LobbyModel.EV_LEAVE
	return LobbyModel.EV_MOVE


func _play_for(ev: StringName, idx: int) -> void:
	match ev:
		LobbyModel.EV_MOVE:
			Sfx.play(&"ui_move")
		LobbyModel.EV_READY:
			_punch_panel(idx)
			Sfx.play(&"ui_confirm")
		LobbyModel.EV_UNREADY, LobbyModel.EV_LEAVE:
			Sfx.play(&"ui_back")


func _process(delta: float) -> void:
	_blink += delta
	if _started:
		return
	if not is_online():
		if all_ready():
			_countdown -= delta
			if _countdown <= 0.0:
				_start()
				return
		else:
			_countdown = UiTheme.tuning().join_start_delay
	_refresh_status()
	var ally := ally_slots()
	for i in mini(_ui.size(), slots.size()):
		if slots[i].state == SlotState.EMPTY and not i in ally:
			(_ui[i]["state"] as Label).modulate.a = 0.55 + 0.45 * absf(sin(_blink * 3.0))
		else:
			(_ui[i]["state"] as Label).modulate.a = 1.0


func _start() -> void:
	_started = true
	model.remember()
	var cfg := build_config()
	match_requested.emit(cfg)
	if auto_start:
		Game.start_match(cfg)


func _back_to_menu() -> void:
	Sfx.play(&"ui_back")
	_started = true
	if is_online():
		Net.leave()
	else:
		model.remember()
	Game.goto(Game.SCENE_MAIN_MENU)


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	add_child(AnimatedBackground.new())
	var u := UiTheme.tuning()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = u.join_margin.x
	root.offset_right = -u.join_margin.x
	root.offset_top = u.join_margin.y
	root.offset_bottom = -u.join_margin.y
	root.add_theme_constant_override("separation", u.join_root_separation)
	add_child(root)

	var title := MenuHelpers.title("CHOOSE YOUR FIGHTERS")
	title.add_theme_font_size_override("font_size", u.join_title_font)
	root.add_child(title)
	root.add_child(_build_room_bar())
	# Player panels and the shared settings panel share the width (no minimum
	# widths: long values are cut with an ellipsis, never pushed off-screen).
	_panel_row = HBoxContainer.new()
	_panel_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_row.add_theme_constant_override("separation", u.join_column_separation)
	root.add_child(_panel_row)
	_rebuild_panels()

	_status_label = MenuHelpers.label("", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	root.add_child(_status_label)
	var online := Net.online_available()
	var hint := MenuHelpers.label(
			"Pad: START/A join  -  D-pad/stick choose  -  A ready  -  B back/leave%s\n"
			% ("  -  Y room" if online else "")
			+ "Keyboard: ENTER join  -  your MOVE keys choose (arrows if alone)  -  LIGHT/JUMP ready  -  PAUSE/ESC back%s"
			% ("  -  TAB room" if online else ""),
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)


## Top bar: room status and its buttons (mouse; pads/keys use Y/TAB, X/C).
func _build_room_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", UiTheme.tuning().join_column_separation)
	_room_label = _fit_label("", &"HintLabel")
	_room_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_room_label)
	# Text-wide buttons, so the address keeps the room.
	_copy_button = MenuHelpers.button("Copy", copy_address)
	_copy_button.focus_mode = Control.FOCUS_NONE
	_copy_button.custom_minimum_size.x = 0
	bar.add_child(_copy_button)
	_room_button = MenuHelpers.button("Open online", room_action)
	_room_button.focus_mode = Control.FOCUS_NONE
	_room_button.custom_minimum_size.x = 0
	_room_button.visible = Net.online_available()
	bar.add_child(_room_button)
	return bar


## (Re)build one panel per slot around the settings panel. Two slots: P1 |
## settings | P2. More (online co-op): compact panels in two columns, odd
## players (P1, P3) on the left, even ones on the right.
func _rebuild_panels() -> void:
	if _panel_row == null:
		return
	for c in _panel_row.get_children():
		_panel_row.remove_child(c)
		c.queue_free()
	_ui.clear()
	_row_labels.clear()
	_coop_labels.clear()
	var u := UiTheme.tuning()
	var compact := slots.size() > 2
	if not compact:
		for i in slots.size():
			var ui := _build_player_panel(i, u.player_color(i), false)
			_ui.append(ui)
			_panel_row.add_child(ui["panel"])
			if i == 0:
				_panel_row.add_child(_build_settings_panel())
		return
	var columns: Array[VBoxContainer] = []
	for side in 2:
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_theme_constant_override("separation", u.join_compact_stack_separation)
		columns.append(column)
	_panel_row.add_child(columns[0])
	_panel_row.add_child(_build_settings_panel())
	_panel_row.add_child(columns[1])
	for i in slots.size():
		var ui := _build_player_panel(i, u.player_color(i), true)
		(ui["panel"] as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
		_ui.append(ui)
		columns[i % 2].add_child(ui["panel"])


## Single-line label that shrinks with an ellipsis instead of widening its panel.
static func _fit_label(text: String, variation: StringName = &"", font_size := 0) -> Label:
	var l := MenuHelpers.label(text, variation, HORIZONTAL_ALIGNMENT_CENTER)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if font_size > 0:
		l.add_theme_font_size_override("font_size", font_size)
	return l


func _build_player_panel(_i: int, color: Color, compact: bool) -> Dictionary:
	var u := UiTheme.tuning()
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := (UiTheme.get_theme().get_stylebox("panel", "PanelContainer") as StyleBoxFlat).duplicate() as StyleBoxFlat
	sb.border_color = color
	sb.set_border_width_all(u.join_panel_border)
	if compact:
		sb.set_content_margin_all(u.join_compact_panel_margin)
	panel.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(col)
	var header := _fit_label("", &"HeaderLabel", u.join_compact_header_font if compact else 0)
	header.add_theme_color_override("font_color", color)
	col.add_child(header)
	var device := _fit_label("", &"HintLabel")
	col.add_child(device)
	var state := _fit_label("", &"HeaderLabel", u.join_compact_state_font if compact else u.join_state_font)
	col.add_child(state)
	var character := _fit_label("", &"", u.join_compact_character_font if compact else u.join_character_font)
	col.add_child(character)
	var hint := MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)
	return {"panel": panel, "header": header, "device": device, "state": state, "character": character,
		"hint": hint, "color": color}


## Shared rows (mode, match rules / co-op run) live once, in the middle
## panel; every row has a label, shown when the mode has that row. They
## scroll when they don't fit; the row under the last-moved cursor is kept in view.
func _build_settings_panel() -> Control:
	var u := UiTheme.tuning()
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = u.join_settings_ratio
	var outer := VBoxContainer.new()
	panel.add_child(outer)
	_settings_header = _fit_label("", &"HeaderLabel")
	outer.add_child(_settings_header)
	_settings_scroll = ScrollContainer.new()
	_settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(_settings_scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", u.join_row_separation)
	_settings_scroll.add_child(col)
	for r in [Row.MODE, Row.SEAT, Row.SEAT_TYPE, Row.SEAT_TEAM, Row.CPU_LEVEL]:
		_add_row_label(col, r)
	_cpu_level_label = _row_labels[Row.CPU_LEVEL]
	_cpu_blurb_label = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_cpu_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_cpu_blurb_label)
	_add_row_label(col, Row.LOCK_TEAMS)
	_add_row_label(col, Row.ROUNDS)
	for r in [Row.COOP_STRUCTURE, Row.ENEMY_COUNT, Row.WAVES, Row.ENEMY_LEVEL, Row.ENEMY_ROSTER,
			Row.ALLY, Row.ALLY_LEVEL, Row.ALLY_CHARACTER, Row.FRIENDLY_FIRE]:
		_coop_labels[r] = _add_row_label(col, r)
	_add_row_label(col, Row.TIMER)
	var how := MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	how.name = "How"
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(how)
	return panel


func _add_row_label(col: Container, r: int) -> Label:
	var l := _fit_label("", &"", UiTheme.tuning().join_row_font)
	col.add_child(l)
	_row_labels[r] = l
	return l


## Scroll the settings list so the row under the last-moved cursor shows.
func _scroll_to_cursor() -> void:
	if _settings_scroll == null or _last_cursor_slot < 0 or _last_cursor_slot >= slots.size():
		return
	var l: Label = _row_labels.get(slots[_last_cursor_slot].cursor)
	if l != null and l.visible:
		_settings_scroll.ensure_control_visible(l)


func _cursor_tags(row: int) -> String:
	var tags: PackedStringArray = []
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor == row:
			tags.append("P%d" % (i + 1))
	return ("[%s] " % ",".join(tags)) if not tags.is_empty() else ""


## "[P1] " for the slot the Seat rows edit while someone's cursor is on them.
func _seat_tags(idx: int) -> String:
	if not model.team_mode() or idx != model.seat:
		return ""
	var tags: PackedStringArray = []
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor in SEAT_ROWS:
			tags.append("P%d" % (i + 1))
	return ("[%s] " % ",".join(tags)) if not tags.is_empty() else ""


func _row_color(row: int) -> Color:
	var u := UiTheme.tuning()
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor == row:
			return u.player_color(i)
	return u.color_text


func _refresh() -> void:
	if _ui.is_empty() and slots.is_empty():
		return
	if _ui.size() != slots.size():
		_rebuild_panels()
	var u := UiTheme.tuning()
	var ids := MenuHelpers.character_ids()
	var mine := local_slots()
	var ally := ally_slots()
	for i in slots.size():
		var s := slots[i]
		var ui := _ui[i]
		var header: Label = ui["header"]
		var state: Label = ui["state"]
		var device: Label = ui["device"]
		var character: Label = ui["character"]
		var hint: Label = ui["hint"]
		var cname := MenuHelpers.character_name(ids[clampi(s.char_index, 0, ids.size() - 1)])
		var remote := is_online() and s.state != SlotState.EMPTY and not i in mine
		character.visible = s.state != SlotState.EMPTY
		if s.type == SlotType.CPU:
			header.text = "CPU"
		elif is_online() and s.display_name != "":
			header.text = s.display_name.to_upper()
		else:
			header.text = "PLAYER %d" % (i + 1)
		header.text = _seat_tags(i) + header.text
		if s.type == SlotType.CPU:
			device.text = "Level %d/%d" % [s.cpu_level + 1, Tuning.cpu.level_count()]
		elif remote:
			device.text = _online_label(s.owner_peer)
		elif s.state != SlotState.EMPTY:
			device.text = MenuHelpers.device_label(_device_kind(i), _device_id(i), binding_slot(i))
		else:
			device.text = "(optional)" if (is_coop() and i > 0) or (model.team_mode() and i > 1) else "-"
		match s.state:
			SlotState.EMPTY:
				state.text = "PRESS START\nOR ENTER" if _can_join_more() else "WAITING FOR\nA PLAYER..."
				state.add_theme_color_override("font_color", u.color_text)
				hint.text = ""
			SlotState.JOINED:
				state.text = "CHOOSE!"
				state.add_theme_color_override("font_color", ui["color"])
				hint.text = "" if remote else "Press A / %s when ready" % _confirm_key_name(i)
			SlotState.READY:
				state.text = "READY!"
				state.add_theme_color_override("font_color", u.color_ready)
				hint.text = "" if remote else "B / %s to cancel" % _back_key_name(i)
		var on_char := s.state == SlotState.JOINED and s.cursor == Row.CHARACTER
		var tags := ""
		if s.type == SlotType.CPU:
			hint.text = "Scroll down past your fighter to pick the CPU's fighter and level" \
				if not model.team_mode() else "Seat rows: fighter, level, team"
			tags = _cursor_tags(Row.CPU_CHARACTER) if i == cpu_slot() else ""
			on_char = tags != ""
		character.text = ("%s<  %s  >" % [tags, cname]) if on_char else cname
		character.add_theme_color_override("font_color", ui["color"] if on_char else u.color_text)
		_refresh_team(i, ui)
		if i in ally:
			_show_ally(ui)
		hint.visible = hint.text != ""
	_refresh_rows()
	_refresh_room()
	_refresh_status()
	_scroll_to_cursor.call_deferred()


## Team versus: the slot's team after its device line ("<  Team A  >",
## in the player's colour, while their cursor is on their TEAM row).
func _refresh_team(i: int, ui: Dictionary) -> void:
	var s := slots[i]
	var device: Label = ui["device"]
	var on_team := s.state == SlotState.JOINED and s.cursor == Row.TEAM
	if on_team:
		device.add_theme_color_override("font_color", ui["color"])
	else:
		device.remove_theme_color_override("font_color")
	if not model.team_mode() or s.state == SlotState.EMPTY:
		return
	var tname := LobbyModel.team_name(s.team)
	device.text += "  -  " + ("<  %s  >" % tname if on_team else tname)


## A place the CPU ally takes (ally_slots): its level and fighter from the
## co-op rows (set there, so no hint).
func _show_ally(ui: Dictionary) -> void:
	var u := UiTheme.tuning()
	var ids := MenuHelpers.character_ids()
	(ui["header"] as Label).text = "CPU ALLY"
	(ui["device"] as Label).text = "Level: %s" % Tuning.cpu.level_name(model.coop_ally_level)
	var state: Label = ui["state"]
	state.text = "READY!"
	state.add_theme_color_override("font_color", u.color_ready)
	var character: Label = ui["character"]
	character.visible = true
	character.text = MenuHelpers.character_name(ids[clampi(model.coop_ally_char, 0, ids.size() - 1)])
	character.add_theme_color_override("font_color", u.color_text)
	(ui["hint"] as Label).text = ""


func _online_label(peer: int) -> String:
	var ms := Net.room.ping_ms(peer) if Net.room != null else -1.0
	return "Online  -  %d ms" % roundi(ms) if ms >= 0.0 else "Online"


## Text of every settings row, hidden when not in rows().
func _refresh_rows() -> void:
	var ids := MenuHelpers.character_ids()
	var waves := model.coop_structure == CoopConfig.Structure.WAVES
	var cpu := cpu_slot()
	var seat := slots[model.seat] if model.seat < slots.size() else null
	var values := {
		Row.MODE: ["Game", LobbyModel.mode_name(model.mode)],
		Row.SEAT: ["Seat", "P%d  %s" % [model.seat + 1, _seat_label(seat)]],
		Row.SEAT_TYPE: ["Seat is", "CPU" if seat != null and seat.type == SlotType.CPU else "Open"],
		Row.SEAT_TEAM: ["Seat team", LobbyModel.team_name(seat.team) if seat != null else ""],
		Row.LOCK_TEAMS: ["Lock teams", "On" if model.lock_teams else "Off"],
		Row.CPU_LEVEL: ["CPU level", Tuning.cpu.level_name(slots[cpu].cpu_level) if cpu >= 0 else ""],
		Row.ROUNDS: ["Rounds to win", str(model.rounds_to_win)],
		Row.TIMER: ["Time limit" if is_coop() else "Timer",
				MenuHelpers.round_time_label(model.time_options[model.time_index])],
		Row.COOP_STRUCTURE: ["Run", "Waves" if waves else "Brawl"],
		Row.ENEMY_COUNT: [("First wave" if model.coop_endless() else "Enemies per wave") if waves else "Enemies",
				str(model.coop_enemy_count)],
		Row.WAVES: ["Waves", "Endless" if model.coop_endless() else str(model.coop_waves)],
		Row.ENEMY_LEVEL: ["Enemy level", Tuning.cpu.level_name(model.coop_enemy_level)],
		Row.ENEMY_ROSTER: ["Enemy roster",
				"Random" if model.coop_roster == 0 else MenuHelpers.character_name(ids[clampi(model.coop_roster - 1, 0, ids.size() - 1)])],
		Row.ALLY: ["Ally", "CPU" if model.coop_ally else "None"],
		Row.ALLY_LEVEL: ["Ally level", Tuning.cpu.level_name(model.coop_ally_level)],
		Row.ALLY_CHARACTER: ["Ally fighter", MenuHelpers.character_name(ids[clampi(model.coop_ally_char, 0, ids.size() - 1)])],
		Row.FRIENDLY_FIRE: ["Friendly fire", "On" if model.friendly_fire else "Off"],
	}
	var shown := rows()
	for r: int in _row_labels:
		var l: Label = _row_labels[r]
		l.visible = r in shown
		l.text = "%s%s  <  %s  >" % [_cursor_tags(r), values[r][0], values[r][1]]
		l.add_theme_color_override("font_color", _row_color(r))
	_cpu_blurb_label.visible = cpu >= 0
	_cpu_blurb_label.text = Tuning.cpu.level_blurb(slots[cpu].cpu_level) if cpu >= 0 else ""
	_settings_header.text = "CO-OP RUN" if is_coop() else "MATCH RULES"
	var how := _settings_header.get_parent().get_node("How") as Label
	how.text = "Rules: the host (up/down row, left/right value)" if is_online() \
		else "Any player: up/down row, left/right value"


## Who sits in a slot, for the Seat row.
func _seat_label(s: LobbyModel.Slot) -> String:
	if s == null:
		return ""
	if s.type == SlotType.CPU:
		return "CPU"
	if s.state == SlotState.EMPTY:
		return "(empty)"
	return s.display_name if is_online() and s.display_name != "" else "Player"


func _refresh_room() -> void:
	if _room_label == null:
		return
	_copy_button.visible = Net.is_host()
	var parts: PackedStringArray = []
	if not is_online():
		parts.append("Local")
		_room_button.text = "Open online"
	elif Net.is_host():
		var port := Net.settings.host_port()
		var lan := UpnpHelper.local_addresses()
		parts.append("Hosting")
		if not lan.is_empty():
			parts.append(_with_port(lan[0], port))
		match Net.upnp.status:
			UpnpHelper.Status.MAPPED:
				parts.append("Public %s (UPnP)" % _with_port(Net.upnp.external_ip, port))
			UpnpHelper.Status.WORKING:
				parts.append("UPnP...")
			UpnpHelper.Status.FAILED:
				parts.append("UPnP failed - forward UDP %d or use LAN/VPN" % port)
		_room_button.text = "Close room"
	else:
		var host := Net.session.peer_name(Transport.HOST_PEER)
		parts.append("Connected to %s" % host)
		var ms := Net.room.ping_ms(Transport.HOST_PEER)
		if ms >= 0.0:
			parts.append("%d ms" % roundi(ms))
		_room_button.text = "Leave"
	if _notice != "":
		parts.append(_notice)
	_room_label.text = "  -  ".join(parts)


func _confirm_key_name(i: int) -> String:
	if _device_kind(i) != Bindings.Kind.KEYBOARD:
		return "START"
	return Bindings.binding_label(Bindings.get_binding(binding_slot(i), Bindings.Kind.KEYBOARD, "LIGHT"))


func _back_key_name(i: int) -> String:
	if _device_kind(i) != Bindings.Kind.KEYBOARD:
		return "BACK"
	return Bindings.binding_label(Bindings.get_binding(binding_slot(i), Bindings.Kind.KEYBOARD, "PAUSE"))


func _refresh_status() -> void:
	if _status_label == null:
		return
	if is_online():
		_refresh_room()
	if _started:
		_status_label.text = "FIGHT!"
	elif is_online() and Net.room.countdown != OnlineRoom.NO_COUNTDOWN:
		_status_label.text = "GET READY... %d" % Net.room.countdown_seconds()
	elif not is_online() and all_ready():
		_status_label.text = "GET READY... %d" % ceili(maxf(_countdown, 0.0))
	elif local_slots().is_empty():
		_status_label.text = "B / ESC: leave the room" if is_online() else "B / ESC: back to menu"
	elif is_online() and is_coop():
		_status_label.text = _coop_online_status()
	elif model.team_mode() and not model.teams_ok():
		_status_label.text = "Waiting for an opponent to join (or add a CPU on the Seat rows)..." if is_online() \
			else "Needs two fighters on two teams (Seat rows add a CPU)"
	elif is_online():
		var waiting := local_slots().all(func(i: int) -> bool: return slots[i].state == SlotState.READY)
		_status_label.text = "Waiting for everyone to ready up..." if waiting else ""
	else:
		_status_label.text = ""


## Online co-op starts once every joined player is ready, however many joined.
func _coop_online_status() -> String:
	var waiting := local_slots().all(func(i: int) -> bool: return slots[i].state == SlotState.READY)
	var text := "Waiting for everyone to ready up..." if waiting else "Ready up to start the run"
	if model.first_free_slot() >= 0:
		text += "  -  more players can still join"
	return text


func _punch_panel(idx: int) -> void:
	if idx >= 0 and idx < _ui.size():
		MenuHelpers.punch(_ui[idx]["panel"])
