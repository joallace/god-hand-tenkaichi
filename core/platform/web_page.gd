class_name WebPage
extends RefCounted
## The browser page around a web build, through JavaScriptBridge: its
## location, history, clipboard and downloads. Every call is a safe no-op
## (or returns empty) off the web, so callers need no feature checks; the
## checks use the real `OS.has_feature("web")`, not PlatformCaps.web, since
## a test pretending to be a browser has no JavaScript.
## Presentation and Net only; never the sim.


static func is_browser() -> bool:
	return OS.has_feature("web")


## window.location: {"href", "protocol" ("https:"), "hostname", "search"
## ("?room=..." or "")}; {} off the web.
static func location() -> Dictionary:
	if not is_browser():
		return {}
	var raw: Variant = JavaScriptBridge.eval("JSON.stringify({href: location.href, protocol: location.protocol,"
			+ " hostname: location.hostname, search: location.search})", true)
	if not raw is String:
		return {}
	var d: Variant = JSON.parse_string(raw)
	if not d is Dictionary:
		return {}
	var out := {}
	for k: String in ["href", "protocol", "hostname", "search"]:
		out[k] = str((d as Dictionary).get(k, ""))
	return out


## history.replaceState to `url` (same origin): no reload, and refresh/back
## won't bring the old URL back.
static func replace_url(url: String) -> void:
	if is_browser():
		JavaScriptBridge.eval("history.replaceState(null, '', %s)" % JSON.stringify(url), true)


## Copy `text`: DisplayServer's clipboard everywhere, plus the async
## navigator.clipboard on web (call from a key/button handler: browsers
## only allow it during a user gesture).
static func copy_text(text: String) -> void:
	DisplayServer.clipboard_set(text)
	if is_browser():
		JavaScriptBridge.eval("navigator.clipboard && navigator.clipboard.writeText(%s).catch(function () {})"
				% JSON.stringify(text), true)


## Offer `bytes` as a file download named `file_name`. Returns false off the web.
static func download(bytes: PackedByteArray, file_name: String, mime: String = "application/octet-stream") -> bool:
	if not is_browser():
		return false
	JavaScriptBridge.download_buffer(bytes, file_name, mime)
	return true
