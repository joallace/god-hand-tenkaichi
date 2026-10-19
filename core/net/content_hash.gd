class_name ContentHash
extends RefCounted
## Fingerprint of the game data the sim depends on (SPEC_ONLINE.md §5.3):
## every tuning Resource (Tuning.REGISTRY, as loaded), every MoveData
## (data/moves) and CharacterDef (data/characters), in sorted path order.
## Two machines with different hand-tuned .tres files would desync, so the
## handshake and replays compare this.
##
## Resources aren't hashed through var_to_bytes(resource) (that encodes an
## object reference, not the data): each is turned into its stored
## properties, sorted by name, with sub-resources by path (or inlined when
## embedded) and Dictionaries as key-sorted pairs.

const DATA_DIRS: Array[String] = ["res://data/moves/", "res://data/characters/"]
const SKIP_PROPS: Array[String] = [
	"script", "resource_path", "resource_name", "resource_local_to_scene", "resource_scene_unique_id",
]


## Hex SHA-256 over the data above.
static func compute() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var keys: Array = Tuning.REGISTRY.keys()
	keys.sort()
	for key: String in keys:
		_feed(ctx, "tuning/" + key, Tuning.get(key))
	for path in data_paths():
		_feed(ctx, path, load(path))
	return ctx.finish().hex_encode()


## Every .tres under DATA_DIRS, sorted (exported builds list "x.tres.remap").
static func data_paths() -> Array[String]:
	var out: Array[String] = []
	for dir in DATA_DIRS:
		for f in DirAccess.get_files_at(dir):
			var name := f.trim_suffix(".remap")
			if name.ends_with(".tres") or name.ends_with(".res"):
				if not out.has(dir + name):
					out.append(dir + name)
	out.sort()
	return out


static func _feed(ctx: HashingContext, label: String, r: Resource) -> void:
	ctx.update(var_to_bytes([label, resource_to_data(r)]))


## Plain data for a Resource: [[property, value], ...] sorted by property.
static func resource_to_data(r: Resource) -> Variant:
	if r == null:
		return null
	var names: Array[String] = []
	for p in r.get_property_list():
		if p["usage"] & PROPERTY_USAGE_STORAGE and not String(p["name"]) in SKIP_PROPS:
			names.append(p["name"])
	names.sort()
	var out: Array = []
	for n in names:
		out.append([n, _plain(r.get(n))])
	return out


static func _plain(v: Variant) -> Variant:
	if v is Resource:
		var r := v as Resource
		if r.resource_path != "" and not r.resource_path.contains("::"):
			return ["$ref", r.resource_path]
		return resource_to_data(r)
	if v is Object:
		return null
	if v is Array:
		var a: Array = []
		for e: Variant in v:
			a.append(_plain(e))
		return a
	if v is Dictionary:
		var pairs: Array = []
		for k: Variant in v:
			pairs.append([var_to_str(k), _plain(v[k])])
		pairs.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
		return pairs
	return v
