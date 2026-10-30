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
## Input mapping only: the sim never sees it.

## SDL-style layout of the W3C standard gamepad, triggers as buttons.
const STANDARD_LAYOUT := "a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,lefttrigger:b6," \
	+ "righttrigger:b7,back:b8,start:b9,leftstick:b10,rightstick:b11,dpup:b12,dpdown:b13," \
	+ "dpleft:b14,dpright:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,"


## Map every connected pad that needs it now, and each one that connects.
static func install() -> void:
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
