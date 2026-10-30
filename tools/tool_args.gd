class_name ToolArgs
extends RefCounted
## `key=value` arguments for the tools/ scenes: `-- key=value ...` after the
## command line on desktop, the page's `?key=value&...` query on web (the
## "Web Tools" export, tools/web_tools.tscn).


static func pairs() -> PackedStringArray:
	if OS.has_feature("web"):
		var q: Variant = JavaScriptBridge.eval("window.location.search")
		if q is String:
			return (q as String).trim_prefix("?").uri_decode().split("&", false)
		return PackedStringArray()
	return OS.get_cmdline_user_args()
