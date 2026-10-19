class_name JoinScreen
extends Control
## Join / setup screen. Each physical device claims a slot, picks a character
## and readies up; when every slot is ready a MatchConfig is built and handed
## to Game.start_match().
##
## Input is read per *device* in _input (event.device), not through global
## ui_* actions, so two pads never steer the same slot.
##
## Gamepad (unjoined): START or A joins the next free slot. B with nobody
##   joined -> main menu.
## Gamepad (joined):   D-pad / left stick up-down picks a row (Character,
##   Rounds, Timer), left-right changes it; A/START = ready; B = un-ready, then
##   leave.
## Keyboard: ENTER joins a keyboard player into the next free slot; that slot
##   number picks the Bindings keyboard layout (slot 0 = A/WASD, slot 1 =
##   B/arrows+numpad). Joined keyboard players navigate with their layout's
##   MOVE keys, ready with their LIGHT or JUMP key (or ENTER once all slots
##   are filled) and back out with their PAUSE key (or ESC). While only one
##   keyboard player is joined, arrow keys also navigate for it.
##
## Modes: the screen is driven by `slot_types`.
##   VERSUS_CPU: slot_types = [HUMAN, CPU]. CPU slots are pre-joined & ready
##     (see _configure_for_mode); the human gets two extra rows, "CPU fighter"
##     and "CPU level" (Tuning.cpu.level_names), to set the CPU up.
##   COOP: slot_types = [HUMAN, HUMAN], both optional: the run starts once at
##     least one human joined and every joined human is ready (solo is fine).
##     Rows after Character set up the run (SPEC.md §9): Mode (Brawl/Waves),
##     Enemies, Waves (Waves only), Enemy level, Enemy roster, Ally (+ ally
##     level/fighter when CPU), Friendly fire, Time limit. Like the versus
##     rules, any joined player edits the shared rows. build_config() puts the
##     humans (and the CPU ally) on team 0 and fills MatchConfig.coop; enemies
##     are created by the director, not listed in players.
##   ONLINE (future): slot_types = [HUMAN, REMOTE]. A lobby/network layer should call
##     set_remote_slot(slot, peer_id, character_id, ready) as messages arrive;
##     only HUMAN slots accept local devices. _build_config() already maps
##     REMOTE -> PlayerSlotConfig.InputKind.NETWORK.

## Emitted with the finished config right before the match starts.
signal match_requested(config: MatchConfig)

enum SlotType { HUMAN, CPU, REMOTE }
enum SlotState { EMPTY, JOINED, READY }
enum Cmd { UP, DOWN, LEFT, RIGHT, CONFIRM, BACK }
enum Row {
	CHARACTER, CPU_CHARACTER, CPU_LEVEL, ROUNDS, TIMER,
	COOP_STRUCTURE, ENEMY_COUNT, WAVES, ENEMY_LEVEL, ENEMY_ROSTER,
	ALLY, ALLY_LEVEL, ALLY_CHARACTER, FRIENDLY_FIRE,
}

## Set before Game.goto(Game.SCENE_JOIN) to choose which mode this screen sets up.
static var pending_mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS
## Settings/characters remembered across visits (Change Setup from results).
static var _memory: Dictionary = {}
## Co-op run setup remembered across visits (separate from versus).
static var _coop_memory: Dictionary = {}

class Slot:
	var type: int = SlotType.HUMAN
	var state: int = SlotState.EMPTY
	var device_kind: int = Bindings.Kind.PAD
	var device_id: int = -1
	var char_index: int = 0
	var cursor: int = Row.CHARACTER
	var peer_id: int = 0
	var join_order: int = 0
	## CPU slots: difficulty, an index into Tuning.cpu.level_names.
	var cpu_level: int = Tuning.cpu.clamp_level(-1)

var mode: MatchConfig.Mode = MatchConfig.Mode.LOCAL_VERSUS
var slots: Array[Slot] = []
var rounds_to_win: int = 2
var time_index: int = 0
## Tests set this false to inspect match_requested without changing scene.
var auto_start: bool = true

# Co-op run setup (COOP mode only).
var coop_structure: int = Tuning.coop.default_structure
var coop_enemy_count: int = Tuning.coop.default_enemy_count
## 1..max_wave_count, or max_wave_count + 1 = endless.
var coop_waves: int = Tuning.coop.default_wave_count
var coop_enemy_level: int = Tuning.cpu.clamp_level(-1)
## 0 = random, else 1 + index into MenuHelpers.character_ids().
var coop_roster: int = 0
var coop_ally: bool = false
var coop_ally_level: int = Tuning.cpu.clamp_level(-1)
var coop_ally_char: int = 0
var friendly_fire: bool = false

var _time_options: PackedInt32Array
var _countdown := 0.0
var _started := false
var _join_counter := 0
var _stick_dir: Dictionary = {}  # device -> Vector2i
var _blink := 0.0

# UI refs per slot
var _ui: Array[Dictionary] = []
var _rounds_label: Label
var _timer_label: Label
var _cpu_level_label: Label
var _cpu_blurb_label: Label
var _status_label: Label
var _coop_labels: Dictionary = {}  # Row -> Label
var _row_labels: Dictionary = {}  # Row -> Label, every row in the settings panel
var _settings_scroll: ScrollContainer
## Slot whose cursor moved last (the settings list follows it).
var _last_cursor_slot := -1


func _ready() -> void:
	MenuHelpers.setup_screen(self)
	var rules: MatchTuning = Tuning.match_rules
	_time_options = rules.round_time_options
	if _time_options.is_empty():
		_time_options = PackedInt32Array([rules.round_time_seconds])
	rounds_to_win = clampi(rules.rounds_to_win, 1, 5)
	time_index = maxi(_time_options.find(rules.round_time_seconds), 0)
	mode = pending_mode
	if is_coop() and _time_options.find(0) >= 0:
		time_index = _time_options.find(0)  # co-op runs default to no time limit
	_configure_for_mode()
	_restore_memory()
	_build_ui()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh()


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.disconnect(_on_joy_connection_changed)


## Slot layout per mode. This is the main hook for VERSUS_CPU / ONLINE.
func _configure_for_mode() -> void:
	var types: Array[int]
	match mode:
		MatchConfig.Mode.VERSUS_CPU:
			types = [SlotType.HUMAN, SlotType.CPU]
		MatchConfig.Mode.ONLINE:
			types = [SlotType.HUMAN, SlotType.REMOTE]
		_:
			types = [SlotType.HUMAN, SlotType.HUMAN]
	slots.clear()
	for t in types:
		var s := Slot.new()
		s.type = t
		if t == SlotType.CPU:
			s.state = SlotState.READY  # TODO(VERSUS_CPU): CPU character pick.
		slots.append(s)


## ONLINE hook: called by the lobby layer for the remote player's slot.
func set_remote_slot(slot: int, peer_id: int, character_id: StringName, ready: bool) -> void:
	if slot < 0 or slot >= slots.size() or slots[slot].type != SlotType.REMOTE:
		return
	var s := slots[slot]
	s.peer_id = peer_id
	s.char_index = maxi(MenuHelpers.character_ids().find(character_id), 0)
	s.state = SlotState.READY if ready else SlotState.JOINED
	_refresh()


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
	var idx := slot_for_device(Bindings.Kind.PAD, e.device)
	if idx < 0:
		match e.button_index:
			JOY_BUTTON_START, JOY_BUTTON_A:
				join(Bindings.Kind.PAD, e.device)
			JOY_BUTTON_B, JOY_BUTTON_BACK:
				if nobody_joined():
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
	var b := Bindings.binding_from_event(e, Bindings.Kind.KEYBOARD)
	if b.is_empty():
		return
	var code: int = b["i"]
	var kb := keyboard_slots()
	# 1) Per-layout keys of each joined keyboard player.
	for idx in kb:
		for action in _KEY_LAYOUT_CMDS:
			if Bindings.get_binding(idx, Bindings.Kind.KEYBOARD, action) == b:
				_command(idx, _KEY_LAYOUT_CMDS[action])
				return
	# 2) Generic keys.
	match code:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if first_free_slot() >= 0:
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
			elif nobody_joined():
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

func slot_for_device(kind: int, device: int) -> int:
	if kind == Bindings.Kind.KEYBOARD:
		return -1  # the keyboard may own several slots (one per layout)
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY \
				and s.device_kind == kind and s.device_id == device:
			return i
	return -1


func keyboard_slots() -> Array[int]:
	var out: Array[int] = []
	for i in slots.size():
		var s := slots[i]
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY and s.device_kind == Bindings.Kind.KEYBOARD:
			out.append(i)
	return out


func first_free_slot() -> int:
	for i in slots.size():
		if slots[i].type == SlotType.HUMAN and slots[i].state == SlotState.EMPTY:
			return i
	return -1


func nobody_joined() -> bool:
	for s in slots:
		if s.type == SlotType.HUMAN and s.state != SlotState.EMPTY:
			return false
	return true


## Claim the next free HUMAN slot for a device. Returns the slot or -1.
func join(kind: int, device: int) -> int:
	if kind == Bindings.Kind.PAD and slot_for_device(kind, device) >= 0:
		return -1
	var idx := first_free_slot()
	if idx < 0:
		return -1
	var s := slots[idx]
	s.state = SlotState.JOINED
	s.device_kind = kind
	s.device_id = device if kind == Bindings.Kind.PAD else -1
	s.cursor = Row.CHARACTER
	_join_counter += 1
	s.join_order = _join_counter
	_punch_panel(idx)
	Sfx.play(&"ui_confirm")
	_refresh()
	return idx


func leave(idx: int) -> void:
	var s := slots[idx]
	if s.type != SlotType.HUMAN:
		return
	s.state = SlotState.EMPTY
	s.device_id = -1
	Sfx.play(&"ui_back")
	_refresh()


func _command(idx: int, cmd: int) -> void:
	var s := slots[idx]
	match s.state:
		SlotState.READY:
			if cmd == Cmd.BACK:
				s.state = SlotState.JOINED
				Sfx.play(&"ui_back")
		SlotState.JOINED:
			match cmd:
				Cmd.UP:
					_last_cursor_slot = idx
					_move_cursor(s, -1)
					Sfx.play(&"ui_move")
				Cmd.DOWN:
					_last_cursor_slot = idx
					_move_cursor(s, 1)
					Sfx.play(&"ui_move")
				Cmd.LEFT:
					_change_row(s, -1)
					Sfx.play(&"ui_move")
				Cmd.RIGHT:
					_change_row(s, 1)
					Sfx.play(&"ui_move")
				Cmd.CONFIRM:
					s.state = SlotState.READY
					_punch_panel(idx)
					Sfx.play(&"ui_confirm")
				Cmd.BACK:
					leave(idx)
					return
	_refresh()


## Rows a joined player can pick, top to bottom, for this mode.
func rows() -> Array[int]:
	if is_coop():
		var r: Array[int] = [Row.CHARACTER, Row.COOP_STRUCTURE, Row.ENEMY_COUNT]
		if coop_structure == CoopConfig.Structure.WAVES:
			r.append(Row.WAVES)
		r.append_array([Row.ENEMY_LEVEL, Row.ENEMY_ROSTER, Row.ALLY])
		if coop_ally:
			r.append_array([Row.ALLY_LEVEL, Row.ALLY_CHARACTER])
		r.append_array([Row.FRIENDLY_FIRE, Row.TIMER])
		return r
	if cpu_slot() >= 0:
		return [Row.CHARACTER, Row.CPU_CHARACTER, Row.CPU_LEVEL, Row.ROUNDS, Row.TIMER]
	return [Row.CHARACTER, Row.ROUNDS, Row.TIMER]


func cpu_slot() -> int:
	for i in slots.size():
		if slots[i].type == SlotType.CPU:
			return i
	return -1


func _move_cursor(s: Slot, dir: int) -> void:
	var r := rows()
	s.cursor = r[posmod(maxi(r.find(s.cursor), 0) + dir, r.size())]


func _change_row(s: Slot, dir: int) -> void:
	var n := MenuHelpers.character_ids().size()
	match s.cursor:
		Row.CHARACTER:
			s.char_index = posmod(s.char_index + dir, maxi(n, 1))
		Row.CPU_CHARACTER:
			var cpu := slots[cpu_slot()]
			cpu.char_index = posmod(cpu.char_index + dir, maxi(n, 1))
		Row.CPU_LEVEL:
			var cpu := slots[cpu_slot()]
			cpu.cpu_level = clampi(cpu.cpu_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ROUNDS:
			rounds_to_win = clampi(rounds_to_win + dir, 1, 5)
		Row.TIMER:
			time_index = posmod(time_index + dir, _time_options.size())
		Row.COOP_STRUCTURE:
			coop_structure = posmod(coop_structure + dir, CoopConfig.Structure.size())
		Row.ENEMY_COUNT:
			coop_enemy_count = clampi(coop_enemy_count + dir, 1, Tuning.coop.max_enemy_count)
		Row.WAVES:
			coop_waves = posmod(coop_waves - 1 + dir, Tuning.coop.max_wave_count + 1) + 1
		Row.ENEMY_LEVEL:
			coop_enemy_level = clampi(coop_enemy_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ENEMY_ROSTER:
			coop_roster = posmod(coop_roster + dir, n + 1)
		Row.ALLY:
			coop_ally = not coop_ally
		Row.ALLY_LEVEL:
			coop_ally_level = clampi(coop_ally_level + dir, 0, Tuning.cpu.level_count() - 1)
		Row.ALLY_CHARACTER:
			coop_ally_char = posmod(coop_ally_char + dir, maxi(n, 1))
		Row.FRIENDLY_FIRE:
			friendly_fire = not friendly_fire
	_fix_cursors()


## Rows hidden by a change (Waves in Brawl, ally rows without an ally) send
## any cursor on them back to the row that controls them.
func _fix_cursors() -> void:
	var r := rows()
	for s in slots:
		if s.cursor in r:
			continue
		match s.cursor:
			Row.WAVES:
				s.cursor = Row.COOP_STRUCTURE
			Row.ALLY_LEVEL, Row.ALLY_CHARACTER:
				s.cursor = Row.ALLY
			_:
				s.cursor = Row.CHARACTER


func all_ready() -> bool:
	if is_coop():
		return not nobody_joined() and slots.all(func(s: Slot) -> bool: return s.state != SlotState.JOINED)
	for s in slots:
		if s.state != SlotState.READY:
			return false
	return not slots.is_empty()


func is_coop() -> bool:
	return mode == MatchConfig.Mode.COOP


func coop_endless() -> bool:
	return coop_waves > Tuning.coop.max_wave_count


func _process(delta: float) -> void:
	_blink += delta
	if _started:
		return
	if all_ready():
		_countdown -= delta
		if _countdown <= 0.0:
			_start()
			return
	else:
		_countdown = UiTheme.tuning().join_start_delay
	_refresh_status()
	for i in _ui.size():
		if slots[i].state == SlotState.EMPTY:
			(_ui[i]["state"] as Label).modulate.a = 0.55 + 0.45 * absf(sin(_blink * 3.0))
		else:
			(_ui[i]["state"] as Label).modulate.a = 1.0


func build_config() -> MatchConfig:
	if is_coop():
		return build_coop_config()
	var cfg := MatchConfig.from_defaults(mode)
	cfg.rounds_to_win = rounds_to_win
	cfg.round_time_seconds = _time_options[time_index]
	cfg.rng_seed = randi()
	var ids := MenuHelpers.character_ids()
	for i in slots.size():
		var s := slots[i]
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = ids[s.char_index] if s.char_index < ids.size() else ids[0]
		match s.type:
			SlotType.CPU:
				p.input_kind = PlayerSlotConfig.InputKind.CPU
				p.cpu_level = s.cpu_level
			SlotType.REMOTE:
				p.input_kind = PlayerSlotConfig.InputKind.NETWORK
				p.peer_id = s.peer_id
			_:
				p.input_kind = PlayerSlotConfig.InputKind.LOCAL
				p.device_kind = s.device_kind
				p.device_id = s.device_id
		cfg.players.append(p)
	return cfg


## COOP: joined humans (in slot order, renumbered from 0) and the optional
## CPU ally on team 0; the run itself in cfg.coop.
func build_coop_config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = _time_options[time_index]
	cfg.rng_seed = randi()
	cfg.friendly_fire = friendly_fire
	var ids := MenuHelpers.character_ids()
	for s in slots:
		if s.type != SlotType.HUMAN or s.state == SlotState.EMPTY:
			continue
		var p := PlayerSlotConfig.new()
		p.slot = cfg.players.size()
		p.team = 0
		p.character_id = ids[clampi(s.char_index, 0, ids.size() - 1)]
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL
		p.device_kind = s.device_kind
		p.device_id = s.device_id
		cfg.players.append(p)
	var c := CoopConfig.new()
	c.structure = coop_structure
	c.enemy_count = coop_enemy_count
	c.endless = coop_structure == CoopConfig.Structure.WAVES and coop_endless()
	if coop_structure == CoopConfig.Structure.WAVES and not c.endless:
		for i in coop_waves:
			c.waves.append(WaveConfig.new())  # count 0 = c.enemy_count
	c.enemy_level = coop_enemy_level
	c.enemy_character = ids[coop_roster - 1] if coop_roster > 0 and coop_roster <= ids.size() else &""
	c.ally_enabled = coop_ally
	c.ally_level = coop_ally_level
	c.ally_character = ids[clampi(coop_ally_char, 0, ids.size() - 1)]
	if coop_ally:
		var a := PlayerSlotConfig.new()
		a.slot = cfg.players.size()
		a.team = 0
		a.character_id = c.ally_character
		a.input_kind = PlayerSlotConfig.InputKind.CPU
		a.cpu_level = coop_ally_level
		cfg.players.append(a)
	cfg.coop = c
	return cfg


func _start() -> void:
	_started = true
	_remember()
	var cfg := build_config()
	match_requested.emit(cfg)
	if auto_start:
		Game.start_match(cfg)


func _back_to_menu() -> void:
	Sfx.play(&"ui_back")
	_remember()
	_started = true
	Game.goto(Game.SCENE_MAIN_MENU)


func _remember() -> void:
	if is_coop():
		_remember_coop()
		return
	var chars: Array[int] = []
	for s in slots:
		chars.append(s.char_index)
	_memory = {"rounds": rounds_to_win, "time": _time_options[time_index], "chars": chars}
	var cpu := cpu_slot()
	if cpu >= 0:
		_memory["cpu_level"] = slots[cpu].cpu_level


func _remember_coop() -> void:
	var chars: Array[int] = []
	for s in slots:
		chars.append(s.char_index)
	_coop_memory = {
		"chars": chars, "time": _time_options[time_index], "structure": coop_structure,
		"enemies": coop_enemy_count, "waves": coop_waves, "enemy_level": coop_enemy_level,
		"roster": coop_roster, "ally": coop_ally, "ally_level": coop_ally_level,
		"ally_char": coop_ally_char, "friendly_fire": friendly_fire,
	}


func _restore_coop_memory() -> void:
	var m := _coop_memory
	if m.is_empty():
		return
	var t := _time_options.find(int(m.get("time", -999)))
	if t >= 0:
		time_index = t
	var n := MenuHelpers.character_ids().size()
	var chars: Array = m.get("chars", [])
	for i in mini(chars.size(), slots.size()):
		slots[i].char_index = clampi(int(chars[i]), 0, n - 1)
	coop_structure = clampi(int(m.get("structure", coop_structure)), 0, CoopConfig.Structure.size() - 1)
	coop_enemy_count = clampi(int(m.get("enemies", coop_enemy_count)), 1, Tuning.coop.max_enemy_count)
	coop_waves = clampi(int(m.get("waves", coop_waves)), 1, Tuning.coop.max_wave_count + 1)
	coop_enemy_level = Tuning.cpu.clamp_level(int(m.get("enemy_level", coop_enemy_level)))
	coop_roster = clampi(int(m.get("roster", coop_roster)), 0, n)
	coop_ally = bool(m.get("ally", coop_ally))
	coop_ally_level = Tuning.cpu.clamp_level(int(m.get("ally_level", coop_ally_level)))
	coop_ally_char = clampi(int(m.get("ally_char", coop_ally_char)), 0, n - 1)
	friendly_fire = bool(m.get("friendly_fire", friendly_fire))


func _restore_memory() -> void:
	if is_coop():
		_restore_coop_memory()
		return
	if _memory.is_empty():
		return
	rounds_to_win = int(_memory.get("rounds", rounds_to_win))
	var t := _time_options.find(int(_memory.get("time", -999)))
	if t >= 0:
		time_index = t
	var chars: Array = _memory.get("chars", [])
	var n := MenuHelpers.character_ids().size()
	for i in mini(chars.size(), slots.size()):
		slots[i].char_index = clampi(int(chars[i]), 0, n - 1)
	var cpu := cpu_slot()
	if cpu >= 0 and _memory.has("cpu_level"):
		slots[cpu].cpu_level = Tuning.cpu.clamp_level(int(_memory["cpu_level"]))


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
	# Player panels and the shared settings panel share the width (no minimum
	# widths: long values are cut with an ellipsis, never pushed off-screen).
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", u.join_column_separation)
	root.add_child(row)

	for i in slots.size():
		var ui := _build_player_panel(i, u.color_p1 if i == 0 else u.color_p2)
		_ui.append(ui)
		row.add_child(ui["panel"])
		if i == 0:
			row.add_child(_build_settings_panel())

	_status_label = MenuHelpers.label("", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER)
	root.add_child(_status_label)
	var hint := MenuHelpers.label(
			"Pad: START/A join  -  D-pad/stick choose  -  A ready  -  B back/leave\n"
			+ "Keyboard: ENTER join  -  your MOVE keys choose (arrows if alone)  -  LIGHT/JUMP ready  -  PAUSE/ESC back",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)


## Single-line label that shrinks with an ellipsis instead of widening its panel.
static func _fit_label(text: String, variation: StringName = &"", font_size := 0) -> Label:
	var l := MenuHelpers.label(text, variation, HORIZONTAL_ALIGNMENT_CENTER)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if font_size > 0:
		l.add_theme_font_size_override("font_size", font_size)
	return l


func _build_player_panel(i: int, color: Color) -> Dictionary:
	var u := UiTheme.tuning()
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := (UiTheme.get_theme().get_stylebox("panel", "PanelContainer") as StyleBoxFlat).duplicate() as StyleBoxFlat
	sb.border_color = color
	sb.set_border_width_all(u.join_panel_border)
	panel.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(col)
	var header := _fit_label("CPU" if slots[i].type == SlotType.CPU else "PLAYER %d" % (i + 1), &"HeaderLabel")
	header.add_theme_color_override("font_color", color)
	col.add_child(header)
	var device := _fit_label("", &"HintLabel")
	col.add_child(device)
	var state := _fit_label("", &"HeaderLabel", u.join_state_font)
	col.add_child(state)
	var character := _fit_label("", &"", u.join_character_font)
	col.add_child(character)
	var hint := MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)
	return {"panel": panel, "device": device, "state": state, "character": character, "hint": hint, "color": color}


## Shared rows (match rules / co-op run) live once, in the middle panel. They
## scroll when they don't fit; the row under the last-moved cursor is kept in view.
func _build_settings_panel() -> Control:
	var u := UiTheme.tuning()
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelBox"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = u.join_settings_ratio
	var outer := VBoxContainer.new()
	panel.add_child(outer)
	outer.add_child(_fit_label("CO-OP RUN" if is_coop() else "MATCH RULES", &"HeaderLabel"))
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
	_cpu_level_label = _fit_label("", &"", u.join_row_font)
	_cpu_blurb_label = MenuHelpers.label("", &"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_cpu_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rounds_label = _fit_label("", &"", u.join_row_font)
	_timer_label = _fit_label("", &"", u.join_row_font)
	for l in [_cpu_level_label, _cpu_blurb_label, _rounds_label, _timer_label]:
		col.add_child(l)
	_cpu_level_label.visible = cpu_slot() >= 0
	_cpu_blurb_label.visible = cpu_slot() >= 0
	_row_labels = {Row.CPU_LEVEL: _cpu_level_label, Row.ROUNDS: _rounds_label, Row.TIMER: _timer_label}
	if is_coop():
		_rounds_label.visible = false  # one run, no rounds
		col.remove_child(_timer_label)
		for r in [Row.COOP_STRUCTURE, Row.ENEMY_COUNT, Row.WAVES, Row.ENEMY_LEVEL, Row.ENEMY_ROSTER,
				Row.ALLY, Row.ALLY_LEVEL, Row.ALLY_CHARACTER, Row.FRIENDLY_FIRE]:
			var l := _fit_label("", &"", u.join_row_font)
			_coop_labels[r] = l
			_row_labels[r] = l
			col.add_child(l)
		col.add_child(_timer_label)
	var how := MenuHelpers.label("Any player: up/down row, left/right value",
			&"HintLabel", HORIZONTAL_ALIGNMENT_CENTER)
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(how)
	return panel


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


func _row_color(row: int) -> Color:
	var u := UiTheme.tuning()
	for i in slots.size():
		if slots[i].state == SlotState.JOINED and slots[i].cursor == row:
			return u.color_p1 if i == 0 else u.color_p2
	return u.color_text


func _refresh() -> void:
	if _ui.is_empty():
		return
	var u := UiTheme.tuning()
	var ids := MenuHelpers.character_ids()
	for i in slots.size():
		var s := slots[i]
		var ui := _ui[i]
		var state: Label = ui["state"]
		var device: Label = ui["device"]
		var character: Label = ui["character"]
		var hint: Label = ui["hint"]
		var cname := MenuHelpers.character_name(ids[clampi(s.char_index, 0, ids.size() - 1)])
		character.visible = s.state != SlotState.EMPTY
		match s.type:
			SlotType.CPU:
				device.text = "Level %d/%d" % [s.cpu_level + 1, Tuning.cpu.level_count()]
			SlotType.REMOTE:
				device.text = "Online peer %d" % s.peer_id if s.peer_id != 0 else "Waiting for opponent..."
			_:
				if s.state != SlotState.EMPTY:
					device.text = MenuHelpers.device_label(s.device_kind, s.device_id, i)
				else:
					device.text = "(optional)" if is_coop() and i > 0 else "-"
		match s.state:
			SlotState.EMPTY:
				state.text = "PRESS START\nOR ENTER"
				state.add_theme_color_override("font_color", u.color_text)
				hint.text = ""
			SlotState.JOINED:
				state.text = "CHOOSE!"
				state.add_theme_color_override("font_color", ui["color"])
				hint.text = "Press A / %s when ready" % _confirm_key_name(i)
			SlotState.READY:
				state.text = "READY!"
				state.add_theme_color_override("font_color", u.color_ready)
				hint.text = "B / %s to cancel" % _back_key_name(i)
		var on_char := s.state == SlotState.JOINED and s.cursor == Row.CHARACTER
		var tags := ""
		if s.type == SlotType.CPU:
			hint.text = "Scroll down past your fighter to pick the CPU's fighter and level"
			tags = _cursor_tags(Row.CPU_CHARACTER)
			on_char = tags != ""
		character.text = ("%s<  %s  >" % [tags, cname]) if on_char else cname
		character.add_theme_color_override("font_color", ui["color"] if on_char else u.color_text)
	var cpu := cpu_slot()
	if cpu >= 0:
		var lvl := slots[cpu].cpu_level
		_cpu_level_label.text = "%sCPU level  <  %s  >" % [_cursor_tags(Row.CPU_LEVEL), Tuning.cpu.level_name(lvl)]
		_cpu_level_label.add_theme_color_override("font_color", _row_color(Row.CPU_LEVEL))
		_cpu_blurb_label.text = Tuning.cpu.level_blurb(lvl)
	_rounds_label.text = "%sRounds to win  <  %d  >" % [_cursor_tags(Row.ROUNDS), rounds_to_win]
	_rounds_label.add_theme_color_override("font_color", _row_color(Row.ROUNDS))
	var timer_name := "Time limit" if is_coop() else "Timer"
	_timer_label.text = "%s%s  <  %s  >" % [_cursor_tags(Row.TIMER), timer_name, MenuHelpers.round_time_label(_time_options[time_index])]
	_timer_label.add_theme_color_override("font_color", _row_color(Row.TIMER))
	if is_coop():
		_refresh_coop_rows()
	_refresh_status()
	_scroll_to_cursor.call_deferred()


## Text of every co-op row, hidden when not in rows().
func _refresh_coop_rows() -> void:
	var ids := MenuHelpers.character_ids()
	var waves := coop_structure == CoopConfig.Structure.WAVES
	var values := {
		Row.COOP_STRUCTURE: ["Mode", "Waves" if waves else "Brawl"],
		Row.ENEMY_COUNT: [("First wave" if coop_endless() else "Enemies per wave") if waves else "Enemies", str(coop_enemy_count)],
		Row.WAVES: ["Waves", "Endless" if coop_endless() else str(coop_waves)],
		Row.ENEMY_LEVEL: ["Enemy level", Tuning.cpu.level_name(coop_enemy_level)],
		Row.ENEMY_ROSTER: ["Enemy roster",
				"Random" if coop_roster == 0 else MenuHelpers.character_name(ids[clampi(coop_roster - 1, 0, ids.size() - 1)])],
		Row.ALLY: ["Ally", "CPU" if coop_ally else "None"],
		Row.ALLY_LEVEL: ["Ally level", Tuning.cpu.level_name(coop_ally_level)],
		Row.ALLY_CHARACTER: ["Ally fighter", MenuHelpers.character_name(ids[clampi(coop_ally_char, 0, ids.size() - 1)])],
		Row.FRIENDLY_FIRE: ["Friendly fire", "On" if friendly_fire else "Off"],
	}
	var shown := rows()
	for r: int in _coop_labels:
		var l: Label = _coop_labels[r]
		l.visible = r in shown
		l.text = "%s%s  <  %s  >" % [_cursor_tags(r), values[r][0], values[r][1]]
		l.add_theme_color_override("font_color", _row_color(r))


func _confirm_key_name(i: int) -> String:
	if slots[i].device_kind != Bindings.Kind.KEYBOARD:
		return "START"
	return Bindings.binding_label(Bindings.get_binding(i, Bindings.Kind.KEYBOARD, "LIGHT"))


func _back_key_name(i: int) -> String:
	if slots[i].device_kind != Bindings.Kind.KEYBOARD:
		return "BACK"
	return Bindings.binding_label(Bindings.get_binding(i, Bindings.Kind.KEYBOARD, "PAUSE"))


func _refresh_status() -> void:
	if _status_label == null:
		return
	if _started:
		_status_label.text = "FIGHT!"
	elif all_ready():
		_status_label.text = "GET READY... %d" % ceili(maxf(_countdown, 0.0))
	elif nobody_joined():
		_status_label.text = "B / ESC: back to menu"
	else:
		_status_label.text = ""


func _punch_panel(idx: int) -> void:
	if idx < _ui.size():
		MenuHelpers.punch(_ui[idx]["panel"])
