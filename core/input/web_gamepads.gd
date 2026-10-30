class_name WebGamepads
extends RefCounted
## Browser gamepads Godot has no mapping for (Bindings installs this on web).
##
## A browser reports a pad either with the W3C "standard" layout (Godot maps
## it: guid "standard") or with raw button/axis indices, and Godot's web
## build then looks the pad up by "<OS><vendor><product>" (or "<OS>Unknown"),
## which its controller database hardly ever has. Unmapped, raw index n
## becomes JoyButton n, and the two numberings differ from button 4 on: the
## D-pad comes out rotated (12 up -> DPAD_DOWN, 13 -> LEFT, 14 -> RIGHT),
## shoulders become Back/Guide, Start becomes LB. Seen with an 8BitDo Pro 3
## on Android Chrome. Browsers order a non-standard pad's buttons like the
## standard layout in practice, so an unknown pad gets that layout (triggers
## as buttons 6/7: the engine only turns them into axes for "standard").
##
## Firefox on Linux is the opposite case: it calls every pad "standard" but
## fills the slots from evdev codes, so a plain HID pad (right stick on
## ABS_Z/RZ, analog triggers on GAS/BRAKE, like an 8BitDo Ultimate 2 over
## Bluetooth) comes out with BTN_X/Y on 3/2 and the stick on axes 4/5
## (Firefox 132) or, read as analog triggers, on buttons 6/7 (Firefox 158),
## which digital LT/RT also write. A mapping can't undo that: for a "standard"
## pad the engine writes buttons 6/7 and axes 4/5 to the same raw axes, so
## FIREFOX_LINUX_SHIM corrects the pad before the engine samples it.
## Xbox-driver pads (fewer than 8 axes) are already right.
## Input mapping only: the sim never sees it.

## SDL-style layout of the W3C standard gamepad, triggers as buttons.
const STANDARD_LAYOUT := "a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,lefttrigger:b6," \
	+ "righttrigger:b7,back:b8,start:b9,leftstick:b10,rightstick:b11,dpup:b12,dpdown:b13," \
	+ "dpleft:b14,dpright:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,"

## Wraps navigator.getGamepads to return Firefox's 8-axis pads in the real
## standard layout. Analog triggers run -1 (rest) to 1 and read 0 until first
## moved. A fractional value on button 6/7 can only be the stick (0.5 at
## center, 0 until first moved), so it tells the two Firefox layouts apart.
## An exact 0 or 1 there is ignored until that axis first moves and again
## after a trigger pull: it's the digital trigger writing over the stick. An
## 8BitDo Ultimate 2 sends its digital release before the analog axis rests.
## A jump straight to 0 or 1 must also hold for 3 samples: a digital press
## may land just before its analog axis moves, which then cancels the jump.
const FIREFOX_LINUX_SHIM := """
(function () {
	const ua = navigator.userAgent;
	if (!navigator.getGamepads || !/Firefox/.test(ua) || !/Linux/.test(ua) || /Android/.test(ua)) {
		return;
	}
	const raw = navigator.getGamepads.bind(navigator);
	const states = {};
	const trigger = function (digital, axis) {
		const value = Math.max(digital, axis === 0 ? 0 : (axis + 1) / 2);
		return {pressed: value > 0, touched: value > 0, value: value};
	};
	const fractional = function (button) {
		return button.value !== 0 && button.value !== 1;
	};
	const track_stick = function (s, i, value, trigger_axis) {
		const exact = value === 0 || value === 1;
		if (trigger_axis !== 0 && trigger_axis > -1) {
			s.ignore[i] = true;
		} else if (!exact) {
			s.ignore[i] = false;
		}
		const jump = Math.abs(value * 2 - 1 - s.stick[i]) > 0.5;
		s.jump[i] = exact && jump && !s.ignore[i] ? s.jump[i] + 1 : 0;
		if (!exact || (!s.ignore[i] && (!jump || s.jump[i] >= 3))) {
			s.stick[i] = value * 2 - 1;
		}
	};
	const fix = function (pad, slot) {
		if (!pad || pad.mapping !== "standard" || pad.axes.length < 8 || pad.buttons.length < 8) {
			delete states[slot];
			return pad;
		}
		let s = states[slot];
		if (!s || s.id !== pad.id) {
			s = states[slot] = {id: pad.id, on_buttons: false, stick: [0, 0], ignore: [true, true], jump: [0, 0]};
		}
		const a = pad.axes;
		const b = Array.from(pad.buttons);
		s.on_buttons = s.on_buttons || fractional(b[6]) || fractional(b[7]);
		if (s.on_buttons) {
			track_stick(s, 0, b[6].value, a[7]);
			track_stick(s, 1, b[7].value, a[6]);
		}
		const digital = s.on_buttons ? [0, 0] : [b[6].value, b[7].value];
		const x = b[3];
		b[3] = b[2];
		b[2] = x;
		b[6] = trigger(digital[0], a[7]);
		b[7] = trigger(digital[1], a[6]);
		return {id: pad.id, index: pad.index, mapping: pad.mapping, connected: pad.connected, timestamp: pad.timestamp,
			axes: [a[0], a[1], s.on_buttons ? s.stick[0] : a[4], s.on_buttons ? s.stick[1] : a[5]], buttons: b};
	};
	navigator.getGamepads = function () {
		const pads = Array.from(raw(), fix);
		for (const slot of Object.keys(states)) {
			if (slot >= pads.length) {
				delete states[slot];
			}
		}
		return pads;
	};
})();
"""


## Map every connected pad that needs it now, and each one that connects.
static func install() -> void:
	JavaScriptBridge.eval(FIREFOX_LINUX_SHIM)
	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)
	for device in Input.get_connected_joypads():
		apply(device)


## Give `device` the standard layout if it has no mapping (web only).
## Returns true when a mapping was added.
static func apply(device: int) -> bool:
	if not device in Input.get_connected_joypads() \
			or not needs_fallback(PlatformCaps.web, Input.is_joy_known(device)):
		return false
	var guid := Input.get_joy_guid(device)
	if guid.is_empty():
		return false
	Input.add_joy_mapping(fallback_mapping(guid, Input.get_joy_name(device)), true)
	print("WebGamepads: '%s' (%s) had no mapping; using the standard layout" % [Input.get_joy_name(device), guid])
	return true


static func needs_fallback(on_web: bool, known: bool) -> bool:
	return on_web and not known


## A mapping line for `guid` (commas would split the name field).
static func fallback_mapping(guid: String, joy_name: String) -> String:
	var n := joy_name.replace(",", " ").strip_edges()
	return "%s,%s,%s" % [guid, n if not n.is_empty() else "Web gamepad", STANDARD_LAYOUT]


static func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		apply(device)
