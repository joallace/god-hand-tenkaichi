class_name UpnpHelper
extends RefCounted
## Threaded UPnP port mapping for a host (SPEC_ONLINE.md §10.5). Discovery
## takes seconds, so it runs on a Thread; `poll()` (called every frame by the
## Net autoload) collects the result on the main thread and emits `finished`.
## `stop()` removes the mapping when the room closes.
##
## The worker only touches its own UPNP object and returns a Dictionary
## through `wait_to_finish()`, so no state is shared while it runs. A stop()
## during discovery waits for the worker (bounded by DISCOVER_TIMEOUT_MS),
## then removes the mapping if it got made; `finished` is not emitted then.
## Where UPnP can't run (PlatformCaps.upnp: web) start() is a no-op and the
## status stays IDLE.

signal finished(ok: bool, external_ip: String, error: String)

enum Status { IDLE, WORKING, MAPPED, FAILED }

## Shown in the router's port-mapping table.
const MAPPING_DESC := "God Hand Tenkaichi"
const PROTOCOL := "UDP"
## Milliseconds to wait for gateway replies, and the multicast TTL.
const DISCOVER_TIMEOUT_MS := 2000
const DISCOVER_TTL := 2
## Lease in seconds (0 = until removed; stop() removes it).
const LEASE_SECONDS := 0

var status: Status = Status.IDLE
var port: int = 0
var external_ip: String = ""
var error_text: String = ""

var _thread: Thread
## The UPNP that made the current mapping (needed to delete it).
var _upnp: UPNP


## Start mapping UDP `p` -> this machine (non-blocking).
func start(p: int) -> void:
	stop()
	if not PlatformCaps.upnp():
		return
	port = p
	external_ip = ""
	error_text = ""
	status = Status.WORKING
	_thread = Thread.new()
	_thread.start(_map_worker.bind(p))


## Main thread, once per frame: deliver a finished discovery.
func poll() -> void:
	if _thread == null or _thread.is_alive():
		return
	var r: Dictionary = _join_thread()
	if r.get("ok", false):
		_upnp = r["upnp"]
		external_ip = r["external_ip"]
		status = Status.MAPPED
	else:
		error_text = r.get("error", "UPnP failed")
		status = Status.FAILED
	finished.emit(status == Status.MAPPED, external_ip, error_text)


## Remove the mapping (if any) and join the thread.
func stop() -> void:
	if _thread != null:
		var r: Dictionary = _join_thread()
		if r.get("ok", false):
			_upnp = r["upnp"]
	if _upnp != null:
		_upnp.delete_port_mapping(port, PROTOCOL)
		_upnp = null
	status = Status.IDLE


func is_working() -> bool:
	return status == Status.WORKING


## This machine's LAN addresses worth showing: private IPv4 first, then
## carrier-grade NAT (Tailscale and similar VPNs), other IPv4, then global
## IPv6. Loopback and link-local are skipped.
static func local_addresses() -> PackedStringArray:
	var private_v4 := PackedStringArray()
	var cgnat_v4 := PackedStringArray()
	var other_v4 := PackedStringArray()
	var v6 := PackedStringArray()
	for a: String in IP.get_local_addresses():
		if a.contains(":"):
			var l := a.to_lower()
			if _is_v6_loopback(l) or l.begins_with("fe80") or l.contains("%"):
				continue
			v6.append(a)
			continue
		var o := a.split(".")
		if o.size() != 4:
			continue
		var b0 := o[0].to_int()
		var b1 := o[1].to_int()
		# Loopback (127/8), "this network" (0/8), link-local (169.254/16).
		if b0 == 127 or b0 == 0 or (b0 == 169 and b1 == 254):
			continue
		# RFC 1918 private ranges, then RFC 6598 shared space (100.64/10).
		if b0 == 10 or (b0 == 172 and b1 >= 16 and b1 <= 31) or (b0 == 192 and b1 == 168):
			private_v4.append(a)
		elif b0 == 100 and b1 >= 64 and b1 <= 127:
			cgnat_v4.append(a)
		else:
			other_v4.append(a)
	var out := PackedStringArray()
	for list in [private_v4, cgnat_v4, other_v4, v6]:
		for a: String in list:
			if not out.has(a):
				out.append(a)
	return out


## "::1" in any spelling (Godot reports "0:0:0:0:0:0:0:1").
static func _is_v6_loopback(a: String) -> bool:
	var groups := a.replace("::", ":").split(":", false)
	for i in groups.size():
		if groups[i].hex_to_int() != (1 if i == groups.size() - 1 else 0):
			return false
	return not groups.is_empty()


func _join_thread() -> Dictionary:
	var r: Variant = _thread.wait_to_finish()
	_thread = null
	return r if r is Dictionary else {}


## Worker thread: discover the gateway and add the mapping.
static func _map_worker(p: int) -> Dictionary:
	var u := UPNP.new()
	var res := u.discover(DISCOVER_TIMEOUT_MS, DISCOVER_TTL)
	if res != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "error": "No UPnP router found (%d)" % res}
	var gw := u.get_gateway()
	if gw == null or not gw.is_valid_gateway():
		return {"ok": false, "error": "No UPnP gateway"}
	res = u.add_port_mapping(p, p, MAPPING_DESC, PROTOCOL, LEASE_SECONDS)
	if res != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "error": "Router refused the port mapping (%d)" % res}
	return {"ok": true, "upnp": u, "external_ip": u.query_external_address()}
