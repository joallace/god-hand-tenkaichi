extends Node
## Determinism lint (SPEC_ONLINE.md §6 rule 2):
##   godot --headless res://tests/determinism_lint_test.tscn
## Scans sim scripts for calls whose results differ between platforms (libm
## transcendentals and the engine helpers built on them), the global RNG and
## wall-clock time. Sim code uses DetMath and a seeded RandomNumberGenerator
## member instead. Prints each offending file:line.
##
## - `DetMath.<fn>` calls never trip it; core/sim/det_math.gd is exempt.
## - Text after `#` (comments, ## docs) is ignored.
## - A proven-safe line ends with `# det-ok: <reason>` (e.g. a view-only node).
## - Not linted (manual rule): iterating a Dictionary is only deterministic if
##   its insertion order is (Godot keeps insertion order); never build sim
##   dictionaries from engine-ordered sources (get_children of nodes added in
##   varying order, signal callbacks, file listings) and then iterate them.

## Directories scanned (recursively).
const SIM_DIRS: Array[String] = ["res://core/match", "res://core/sim", "res://core/input", "res://gameplay"]
## View-only or device-facing scripts inside SIM_DIRS.
const EXEMPT: Array[String] = [
	"res://core/sim/det_math.gd",                  # the deterministic implementation itself
	"res://core/input/local_device_input.gd",      # reads devices; produces InputFrames
	"res://core/input/bindings_store.gd",          # control bindings, not sim state
	"res://gameplay/fighter/fighter_visual.gd",    # read-only view of the fighter
]
const ALLOW_TAG := "# det-ok:"
## [regex, what]. Matched against the code part of each line after
## `DetMath.<name>` calls are blanked out.
const RULES := [
	["(?<![\\w.])(sin|cos|tan|sinh|cosh|tanh|pow|exp|log|ease)\\(", "libm transcendental"],
	["\\b(atan|asin|acos)", "libm inverse trig"],
	["\\*\\*", "** (pow)"],
	["\\.angle\\(\\)", ".angle()"],
	["\\bangle_to\\b", "angle_to"],
	["\\bfrom_angle\\b", "from_angle"],
	["\\brotated\\(", "rotated()"],
	["\\.rotate(_x|_y|_z|_object_local)?\\(", "Node3D.rotate*()"],
	["\\brotation(_degrees)?\\b", "rotation (euler <-> basis)"],
	["slerp", "slerp"],
	["\\blook_at", "look_at"],
	["\\blooking_at", "looking_at"],
	["(from|get)_euler", "euler conversion"],
	["\\bBasis\\(", "Basis(axis, angle)"],
	["Quaternion", "Quaternion"],
	["lerp_angle", "lerp_angle"],
	["(?<![\\w.])(randf|randi|randfn|randf_range|randi_range|randomize|seed)\\(", "global RNG"],
	["\\bTime\\.", "wall-clock time"],
	["OS\\.get_ticks", "wall-clock time"],
]

var _fails := 0
var _strip_detmath := RegEx.create_from_string("DetMath\\.\\w+")


func _ready() -> void:
	_test_rules_self_check()
	_test_scan()
	print("DETERMINISM_LINT %s (%d failures)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func check(cond: bool, what: String) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


## The linter itself: catches what it should, lets the allowed forms through.
func _test_rules_self_check() -> void:
	var regs := _compile()
	var bad := ["var a := sin(x)", "y = atan2(a, b)", "v.rotated(Vector3.UP, a)", "f.angle_to(d)",
		"global_basis = Basis(Vector3.UP, y)", "Basis.looking_at(d)", "var r := randf()",
		"randi_range(0, 3)", "var t := Time.get_ticks_msec()", "x ** 2.0", "v.angle()",
		"q := Quaternion(a, b)", "lerp_angle(a, b, t)", "Vector2.from_angle(a)"]
	var good := ["var a := DetMath.sin(x)", "y = DetMath.atan2(a, b)", "rng.randf()",
		"_rng.randi_range(0, 3)", "var b := DetMath.yaw_basis(y)", "# sin(x) in a comment",
		"x = 1  ## doc: rotated( angle_to", "basin(x)", "v.rotated(UP, a)  # det-ok: test",
		"\"sin(\" in a string", "var basis := global_basis"]
	var missed: Array[String] = []
	for s in bad:
		if _offences(s, regs).is_empty():
			missed.append(s)
	var flagged: Array[String] = []
	for s in good:
		if not _offences(s, regs).is_empty():
			flagged.append(s)
	check(missed.is_empty(), "lint catches every bad form %s" % str(missed))
	check(flagged.is_empty(), "lint allows DetMath / rng members / comments / det-ok %s" % str(flagged))


func _test_scan() -> void:
	var regs := _compile()
	var files: Array[String] = []
	for d in SIM_DIRS:
		_collect(d, files)
	var hits: Array[String] = []
	for path in files:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			for what in _offences(lines[i], regs):
				hits.append("%s:%d: %s: %s" % [path, i + 1, what, lines[i].strip_edges()])
	for h in hits:
		print("  " + h)
	check(files.size() > 10, "scanned %d sim scripts" % files.size())
	check(hits.is_empty(), "no non-deterministic calls in sim code (%d found)" % hits.size())


func _compile() -> Array[RegEx]:
	var out: Array[RegEx] = []
	for r in RULES:
		out.append(RegEx.create_from_string(r[0]))
	return out


## What each rule found in one line (empty = clean).
func _offences(line: String, regs: Array[RegEx]) -> Array[String]:
	var out: Array[String] = []
	var parts := _split(line)
	if parts[1].contains(ALLOW_TAG):
		return out
	var code := _strip_detmath.sub(parts[0], "", true)
	for i in regs.size():
		if regs[i].search(code) != null:
			out.append(RULES[i][1])
	return out


## [code with string literal contents dropped, comment from `#` on].
func _split(line: String) -> Array[String]:
	var out := ""
	var quote := ""
	var i := 0
	while i < line.length():
		var c := line[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
				out += c
		elif c == "\"" or c == "'":
			quote = c
			out += c
		elif c == "#":
			return [out, line.substr(i)]
		else:
			out += c
		i += 1
	return [out, ""]


func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		check(false, "open " + dir)
		return
	for f in d.get_files():
		var path := dir.path_join(f)
		if f.ends_with(".gd") and path not in EXEMPT:
			out.append(path)
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
