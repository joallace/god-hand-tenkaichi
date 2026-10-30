extends Node
## WebGamepads: an unmapped browser pad (an 8BitDo Pro 3 on Android Chrome
## came through raw, D-pad rotated) gets the standard layout; a known pad and
## desktop are left alone. Real pads aren't touched: a high, empty device id.
## Run as a scene:  godot --headless res://tests/web_gamepad_test.tscn

const DEVICE := 7
const GUID := "AndroidUnknown"  # a non-standard pad without vendor/product

var _failures := 0


func _ready() -> void:
	var real_web := PlatformCaps.web
	var line := WebGamepads.fallback_mapping(GUID, "8BitDo, Pro 3")
	_check(line.begins_with(GUID + ",8BitDo  Pro 3,") and line.contains("dpup:b12")
			and line.contains("dpright:b15") and line.contains("lefttrigger:b6"),
			"mapping line: guid, comma-free name, standard layout (%s)" % line)
	_check(WebGamepads.fallback_mapping(GUID, "").contains(",Web gamepad,"), "mapping line: a nameless pad gets a name")
	_check(WebGamepads.needs_fallback(true, false) and not WebGamepads.needs_fallback(true, true)
			and not WebGamepads.needs_fallback(false, false), "fallback only on web, only for unknown pads")

	# GDScript can't register a fake pad (Input.joy_connection_changed is only a
	# signal there), so apply() is checked on an id with no pad: nothing to map.
	PlatformCaps.web = true
	_check(not WebGamepads.apply(DEVICE), "no pad on the id: nothing mapped")
	PlatformCaps.web = real_web

	print("WEB GAMEPAD TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond
