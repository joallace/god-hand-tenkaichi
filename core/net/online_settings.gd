class_name OnlineSettings
extends RefCounted
## Per-user online settings (SPEC_ONLINE.md §14), not tuning: profile name,
## input delay mode, host port override, recent hosts, debug net overlay.
## Stored in `user://online.cfg`; the Net autoload owns one instance
## (`Net.settings`). Tests point `path` at a temp file.

const DEFAULT_PATH := "user://online.cfg"
## input_delay value meaning "Auto" (TimeSync.auto_input_delay from RTT).
const DELAY_AUTO := -1
## port value meaning "use Tuning.net.default_port".
const PORT_DEFAULT := 0
const MAX_PORT := 65535
const DEFAULT_NAME := "Player"

const _SECTION := "online"
const _HOSTS := "recent_hosts"

var path := DEFAULT_PATH
var player_name: String = DEFAULT_NAME
## DELAY_AUTO or a fixed delay in frames (0..Tuning.net.input_delay_max).
var input_delay: int = DELAY_AUTO
## PORT_DEFAULT or a UDP port to host on.
var port: int = PORT_DEFAULT
## Show the debug net overlay in online matches.
var net_overlay := false
## Most recent first: [{"address": String, "name": String, "date": String}],
## at most Tuning.net.recent_hosts_max.
var recent_hosts: Array[Dictionary] = []


static func load_from(p: String = DEFAULT_PATH) -> OnlineSettings:
	var s := OnlineSettings.new()
	s.path = p
	s.reload()
	return s


## Re-read `path` (missing file = defaults).
func reload() -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	set_player_name(str(cf.get_value(_SECTION, "name", player_name)))
	set_input_delay(_as_int(cf.get_value(_SECTION, "input_delay", input_delay), DELAY_AUTO))
	set_port(_as_int(cf.get_value(_SECTION, "port", port), PORT_DEFAULT))
	net_overlay = cf.get_value(_SECTION, "net_overlay", false) == true
	recent_hosts.clear()
	var hosts: Variant = cf.get_value(_SECTION, _HOSTS, [])
	if hosts is Array:
		for h: Variant in hosts:
			if h is Dictionary and h.get("address") is String and not (h["address"] as String).is_empty():
				recent_hosts.append({"address": h["address"], "name": str(h.get("name", "")),
					"date": str(h.get("date", ""))})
	_trim_hosts()


func save() -> Error:
	var cf := ConfigFile.new()
	cf.set_value(_SECTION, "name", player_name)
	cf.set_value(_SECTION, "input_delay", input_delay)
	cf.set_value(_SECTION, "port", port)
	cf.set_value(_SECTION, "net_overlay", net_overlay)
	cf.set_value(_SECTION, _HOSTS, recent_hosts)
	return cf.save(path)


## Sets the name if Session.sanitize_name accepts it; returns whether it did.
func set_player_name(n: String) -> bool:
	var s := Session.sanitize_name(n)
	if s.is_empty():
		return false
	player_name = s
	return true


func set_input_delay(d: int) -> void:
	input_delay = DELAY_AUTO if d < 0 else mini(d, Tuning.net.input_delay_max)


func set_port(p: int) -> void:
	port = p if p >= 1 and p <= MAX_PORT else PORT_DEFAULT


## The port a host binds.
func host_port() -> int:
	return port if port != PORT_DEFAULT else Tuning.net.default_port


func is_auto_delay() -> bool:
	return input_delay == DELAY_AUTO


## Remember a successful join (moves an existing entry to the top).
func add_recent_host(address: String, host_name: String, date: String = "") -> void:
	var a := address.strip_edges()
	if a.is_empty():
		return
	remove_recent_host(a)
	if date.is_empty():
		date = Time.get_date_string_from_system()
	recent_hosts.push_front({"address": a, "name": host_name, "date": date})
	_trim_hosts()


func remove_recent_host(address: String) -> void:
	for i in range(recent_hosts.size() - 1, -1, -1):
		if recent_hosts[i]["address"] == address:
			recent_hosts.remove_at(i)


func _trim_hosts() -> void:
	while recent_hosts.size() > Tuning.net.recent_hosts_max:
		recent_hosts.pop_back()


static func _as_int(v: Variant, fallback: int) -> int:
	return v if v is int else fallback
