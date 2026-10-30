extends Node
## WebGamepads: an unmapped browser pad (an 8BitDo Pro 3 on Android Chrome
## came through raw, D-pad rotated) gets the standard layout; a known pad and
## desktop are left alone. Real pads aren't touched: a high, empty device id.
## Firefox on Linux's false "standard" layout is fixed by a getGamepads shim,
## run here under node (skipped without it) on layouts captured from Firefox.
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

	_check_firefox_shim()

	print("WEB GAMEPAD TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


## Node harness: a fake navigator, the shim, then the pad Godot would sample.
## Arguments: <ua> <axis count> <button count> <analog trigger or "">. Axis i
## reads i / 10 and button i reads i / 100, so the output shows what moved.
const NODE_HARNESS := """
const [ua, axes, buttons, trigger] = process.argv.slice(1);
const pad = {id: '2dc8-6012-8BitDo Ultimate 2 Wireless', index: 0, mapping: 'standard', connected: true, timestamp: 1,
	axes: Array.from({length: +axes}, (_, i) => (trigger && i >= 6 ? +trigger : i / 10)),
	buttons: Array.from({length: +buttons}, (_, i) => ({pressed: i > 0, touched: i > 0, value: i / 100}))};
const nav = {userAgent: ua, getGamepads: () => [null, pad]};
new Function('navigator', process.env.SHIM)(nav);
const [gap, p] = nav.getGamepads();
console.log(JSON.stringify({gap, same: p === pad, axes: p.axes, buttons: p.buttons.map((b) => b.value), index: p.index, id: p.id}));
"""
const UA_FIREFOX_LINUX := "Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0"
const UA_FIREFOX_ANDROID := "Mozilla/5.0 (Android 14; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0"
const UA_FIREFOX_WINDOWS := "Mozilla/5.0 (Windows NT 10.0; rv:132.0) Gecko/20100101 Firefox/132.0"
const UA_CHROME_LINUX := "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/150.0.0.0 Safari/537.36"


func _check_firefox_shim() -> void:
	var out: Array = []
	if OS.execute("node", ["--version"], out, true) != 0:
		print("SKIP Firefox shim checks: no node")
		return
	var hid := _run_shim(UA_FIREFOX_LINUX, 8, 28)
	_check(hid.get("axes") == [0.0, 0.1, 0.4, 0.5], "HID pad: right stick moves from axes 4/5 to 2/3, four axes left (%s)" % str(hid.get("axes")))
	var b: Array = hid.get("buttons", [])
	_check(b.size() == 28 and is_equal_approx(b[2], 0.03) and is_equal_approx(b[3], 0.02), "HID pad: X and Y swapped back")
	_check(b.size() == 28 and is_equal_approx(b[6], 0.85) and is_equal_approx(b[7], 0.8), "HID pad: LT reads BRAKE (axis 7), RT reads GAS (axis 6), rescaled to 0..1")
	_check(b.size() == 28 and is_equal_approx(b[0], 0.0) and is_equal_approx(b[12], 0.12), "HID pad: the other buttons keep their slot")
	_check(hid.get("gap") == null and hid.get("index") == 0.0 and str(hid.get("id")).begins_with("2dc8-6012-"), "HID pad: empty slots, index and id kept")
	var resting: Array = _run_shim(UA_FIREFOX_LINUX, 8, 28, "-1").get("buttons", [])
	_check(resting.size() == 28 and is_equal_approx(resting[6], 0.06) and is_equal_approx(resting[7], 0.07), "HID pad: a resting analog trigger (-1) keeps the button's value")
	var unmoved: Array = _run_shim(UA_FIREFOX_LINUX, 8, 28, "0").get("buttons", [])
	_check(unmoved.size() == 28 and is_equal_approx(unmoved[6], 0.06) and is_equal_approx(unmoved[7], 0.07), "HID pad: a never-moved analog trigger (0) is no half press")
	var half: Array = _run_shim(UA_FIREFOX_LINUX, 8, 28, "-0.5").get("buttons", [])
	_check(half.size() == 28 and is_equal_approx(half[6], 0.25), "HID pad: a quarter pull (-0.5) reads 0.25")
	_check(_run_shim(UA_FIREFOX_LINUX, 8, 4).get("same") == true, "pad with few buttons: untouched, no throw")
	_check(_run_shim(UA_FIREFOX_LINUX, 6, 17).get("same") == true, "Xbox-driver pad (6 axes): already right, untouched")
	_check(_run_shim(UA_CHROME_LINUX, 8, 28).get("same") == true, "Chrome: untouched")
	_check(_run_shim(UA_FIREFOX_ANDROID, 8, 28).get("same") == true, "Firefox on Android: untouched")
	_check(_run_shim(UA_FIREFOX_WINDOWS, 8, 28).get("same") == true, "Firefox on Windows: untouched")


func _run_shim(ua: String, axes: int, buttons: int, trigger_rest := "") -> Dictionary:
	OS.set_environment("SHIM", WebGamepads.FIREFOX_LINUX_SHIM)
	var out: Array = []
	if OS.execute("node", ["-e", NODE_HARNESS, ua, str(axes), str(buttons), trigger_rest], out, true) != 0:
		print("node failed: %s" % str(out))
		return {}
	var parsed: Variant = JSON.parse_string(out[0])
	return parsed if parsed is Dictionary else {}


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond
