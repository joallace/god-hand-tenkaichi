extends Node
## Autoload "Bindings": rebindable controls per player slot, persisted to
## user://controls.cfg. The controls settings screen edits these;
## LocalDeviceInput reads them every tick (so changes apply immediately).
##
## A binding is a small Dictionary so it serializes trivially:
##   {"t": "btn",  "i": JOY_BUTTON_X}
##   {"t": "axis", "i": JOY_AXIS_TRIGGER_RIGHT, "s": 1}   # sign of the axis
##   {"t": "key",  "i": KEY_J}                            # physical keycode
##
## Sticks on gamepads are fixed (left = move, right = dodge); the d-pad also
## moves. On keyboard, move and dodge directions are rebindable actions.
##
## Defaults follow Budokai Tenkaichi: GUARD also teleports/vanishes when timed,
## CHARGE + HEAVY is the special, HEAVY at range is a ki blast (see Fighter).
## BLAST / SPECIAL / TELEPORT are optional dedicated shortcuts, unbound ({})
## by default. THROW (RB) grabs through guard; TAUNT (RT) taunts for ki;
## TARGET (LB) cycles / locks the target among several enemies.

signal changed(slot: int)

const SAVE_PATH := "user://controls.cfg"
## Bump when the defaults change incompatibly; older saves are discarded.
const SAVE_VERSION := 2
const SLOT_COUNT := 2

enum Kind { PAD, KEYBOARD }

## Button actions (names match InputFrame.Btn keys).
const BUTTON_ACTIONS: Array[String] = [
	"LIGHT", "HEAVY", "BLAST", "JUMP", "GUARD", "CHARGE", "SPECIAL", "TELEPORT", "DASH", "PAUSE",
	"THROW", "TAUNT", "TARGET",
]
## Keyboard-only directional actions.
const KEYBOARD_DIR_ACTIONS: Array[String] = [
	"MOVE_FORWARD", "MOVE_BACK", "MOVE_LEFT", "MOVE_RIGHT",
	"DODGE_FORWARD", "DODGE_BACK", "DODGE_LEFT", "DODGE_RIGHT",
]

const DEFAULT_PAD := {
	"LIGHT": {"t": "btn", "i": JOY_BUTTON_X},
	"HEAVY": {"t": "btn", "i": JOY_BUTTON_Y},
	"BLAST": {},
	"JUMP": {"t": "btn", "i": JOY_BUTTON_A},
	"GUARD": {"t": "btn", "i": JOY_BUTTON_B},
	"CHARGE": {"t": "axis", "i": JOY_AXIS_TRIGGER_LEFT, "s": 1},
	"SPECIAL": {},
	"TELEPORT": {},
	"DASH": {"t": "btn", "i": JOY_BUTTON_LEFT_STICK},
	"PAUSE": {"t": "btn", "i": JOY_BUTTON_START},
	"THROW": {"t": "btn", "i": JOY_BUTTON_RIGHT_SHOULDER},
	"TAUNT": {"t": "axis", "i": JOY_AXIS_TRIGGER_RIGHT, "s": 1},
	"TARGET": {"t": "btn", "i": JOY_BUTTON_LEFT_SHOULDER},
}

const DEFAULT_KEYBOARD: Array[Dictionary] = [
	{ # Slot 0 / layout A: WASD + IJKL dodge + left-hand cluster
		"MOVE_FORWARD": {"t": "key", "i": KEY_W}, "MOVE_BACK": {"t": "key", "i": KEY_S},
		"MOVE_LEFT": {"t": "key", "i": KEY_A}, "MOVE_RIGHT": {"t": "key", "i": KEY_D},
		"DODGE_FORWARD": {"t": "key", "i": KEY_T}, "DODGE_BACK": {"t": "key", "i": KEY_G},
		"DODGE_LEFT": {"t": "key", "i": KEY_F}, "DODGE_RIGHT": {"t": "key", "i": KEY_H},
		"LIGHT": {"t": "key", "i": KEY_J}, "HEAVY": {"t": "key", "i": KEY_I},
		"BLAST": {}, "JUMP": {"t": "key", "i": KEY_K},
		"GUARD": {"t": "key", "i": KEY_L}, "CHARGE": {"t": "key", "i": KEY_U},
		"SPECIAL": {}, "TELEPORT": {},
		"DASH": {"t": "key", "i": KEY_SHIFT}, "PAUSE": {"t": "key", "i": KEY_ESCAPE},
		"THROW": {"t": "key", "i": KEY_O}, "TAUNT": {"t": "key", "i": KEY_Y},
		"TARGET": {"t": "key", "i": KEY_Q},
	},
	{ # Slot 1 / layout B: arrows + numpad
		"MOVE_FORWARD": {"t": "key", "i": KEY_UP}, "MOVE_BACK": {"t": "key", "i": KEY_DOWN},
		"MOVE_LEFT": {"t": "key", "i": KEY_LEFT}, "MOVE_RIGHT": {"t": "key", "i": KEY_RIGHT},
		"DODGE_FORWARD": {"t": "key", "i": KEY_KP_8}, "DODGE_BACK": {"t": "key", "i": KEY_KP_5},
		"DODGE_LEFT": {"t": "key", "i": KEY_KP_4}, "DODGE_RIGHT": {"t": "key", "i": KEY_KP_6},
		"LIGHT": {"t": "key", "i": KEY_KP_1}, "HEAVY": {"t": "key", "i": KEY_KP_2},
		"BLAST": {}, "JUMP": {"t": "key", "i": KEY_KP_0},
		"GUARD": {"t": "key", "i": KEY_KP_3}, "CHARGE": {"t": "key", "i": KEY_KP_7},
		"SPECIAL": {}, "TELEPORT": {},
		"DASH": {"t": "key", "i": KEY_KP_ENTER}, "PAUSE": {"t": "key", "i": KEY_BACKSPACE},
		"THROW": {"t": "key", "i": KEY_KP_9}, "TAUNT": {"t": "key", "i": KEY_KP_ADD},
		"TARGET": {"t": "key", "i": KEY_KP_SUBTRACT},
	},
]

## Gamepad buttons added to the built-in ui_* actions (Godot's defaults leave
## ui_accept / ui_cancel keyboard-only), so every menu works with any pad.
const UI_PAD_BUTTONS := {
	&"ui_accept": [JOY_BUTTON_A],
	&"ui_cancel": [JOY_BUTTON_B],
}

## _maps[slot][Kind] -> Dictionary(action -> binding)
var _maps: Array = []


func _ready() -> void:
	_add_ui_pad_buttons()
	for slot in SLOT_COUNT:
		_maps.append([DEFAULT_PAD.duplicate(true), DEFAULT_KEYBOARD[slot].duplicate(true)])
	load_from_disk()


static func _add_ui_pad_buttons() -> void:
	for action: StringName in UI_PAD_BUTTONS:
		for button: int in UI_PAD_BUTTONS[action]:
			var e := InputEventJoypadButton.new()
			e.device = -1  # any device
			e.button_index = button as JoyButton
			if not InputMap.action_has_event(action, e):
				InputMap.action_add_event(action, e)


func actions_for(kind: Kind) -> Array[String]:
	if kind == Kind.PAD:
		return BUTTON_ACTIONS.duplicate()
	var a: Array[String] = KEYBOARD_DIR_ACTIONS.duplicate()
	a.append_array(BUTTON_ACTIONS)
	return a


func get_binding(slot: int, kind: Kind, action: String) -> Dictionary:
	return _maps[slot][kind].get(action, {})


func set_binding(slot: int, kind: Kind, action: String, binding: Dictionary) -> void:
	_maps[slot][kind][action] = binding
	changed.emit(slot)


func reset_defaults(slot: int) -> void:
	_maps[slot] = [DEFAULT_PAD.duplicate(true), DEFAULT_KEYBOARD[slot].duplicate(true)]
	changed.emit(slot)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", SAVE_VERSION)
	for slot in SLOT_COUNT:
		for kind in [Kind.PAD, Kind.KEYBOARD]:
			var section := "slot%d_%s" % [slot, Kind.find_key(kind)]
			for action in _maps[slot][kind]:
				cfg.set_value(section, action, _maps[slot][kind][action])
	cfg.save(SAVE_PATH)


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	if cfg.get_value("meta", "version", 1) < SAVE_VERSION:
		return  # saved against old defaults; start fresh
	# Saved keys overlay the defaults, so actions added after the file was
	# written (e.g. TARGET) keep their default binding.
	for slot in SLOT_COUNT:
		for kind in [Kind.PAD, Kind.KEYBOARD]:
			var section := "slot%d_%s" % [slot, Kind.find_key(kind)]
			if not cfg.has_section(section):
				continue
			for action in cfg.get_section_keys(section):
				var b = cfg.get_value(section, action)
				if b is Dictionary:
					_maps[slot][kind][action] = b


# --- Reading bindings -------------------------------------------------------

## Is this binding active for the given joypad device (ignored for keys)?
static func is_binding_active(b: Dictionary, device: int, trigger_threshold: float) -> bool:
	match b.get("t", ""):
		"btn":
			return Input.is_joy_button_pressed(device, b["i"])
		"axis":
			return Input.get_joy_axis(device, b["i"]) * b.get("s", 1) > trigger_threshold
		"key":
			return Input.is_physical_key_pressed(b["i"])
	return false


## Convert a raw input event (from the rebinding screen) into a binding for
## `kind`, or {} if the event doesn't fit that kind.
static func binding_from_event(event: InputEvent, kind: Kind, axis_threshold: float = 0.6) -> Dictionary:
	if kind == Kind.KEYBOARD and event is InputEventKey and event.pressed and not event.echo:
		var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		return {"t": "key", "i": code}
	if kind == Kind.PAD:
		if event is InputEventJoypadButton and event.pressed:
			return {"t": "btn", "i": event.button_index}
		# Only triggers are bindable as axes; sticks are reserved for move/dodge.
		if event is InputEventJoypadMotion and absf(event.axis_value) > axis_threshold \
				and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
			return {"t": "axis", "i": event.axis, "s": signi(roundi(event.axis_value))}
	return {}


static func binding_label(b: Dictionary) -> String:
	match b.get("t", ""):
		"key":
			return OS.get_keycode_string(b["i"])
		"btn":
			return _PAD_BUTTON_NAMES.get(b["i"], "Button %d" % b["i"])
		"axis":
			return _PAD_AXIS_NAMES.get(b["i"], "Axis %d" % b["i"])
	return "—"


const _PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_START: "Start", JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide",
	JOY_BUTTON_DPAD_UP: "D-Up", JOY_BUTTON_DPAD_DOWN: "D-Down",
	JOY_BUTTON_DPAD_LEFT: "D-Left", JOY_BUTTON_DPAD_RIGHT: "D-Right",
}
const _PAD_AXIS_NAMES := {JOY_AXIS_TRIGGER_LEFT: "LT", JOY_AXIS_TRIGGER_RIGHT: "RT"}
