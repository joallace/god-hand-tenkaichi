extends Node
## Main scene of the "Web Tools" export (feature tag `web_tools`): runs one
## headless tool in the browser, picked by the page query, its output read
## from the browser console (tools/web_tools.sh does all of it):
##   ?tool=replay                 tools/replay_hash with replay=all: the
##                                desktop-recorded replays in tools/replays/,
##                                REPLAY_HASH lines (cross-runtime determinism)
##   ?tool=bench&mode=coop&humans=2&enemies=4&driver=0
##                                tools/net_bench (NET_BENCH lines)
##   ?tool=net_peer&role=guest&code=ABCDEF&signal=ws://...
##                                tools/net_peer: one peer of a WebRTC match
##                                (NET_PEER lines; tools/crossplay_e2e.sh)
## Both read the rest of the query as their `key=value` args (ToolArgs).
## Each tool ends with its own `... DONE` line (REPLAY_HASH DONE, NET_BENCH
## DONE) before calling quit().

const TOOLS := {
	"replay": "res://tools/replay_hash.tscn",
	"bench": "res://tools/net_bench.tscn",
	"net_peer": "res://tools/net_peer.tscn",
}


func _ready() -> void:
	var tool := "replay"
	for a in ToolArgs.pairs():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "tool":
			tool = kv[1]
	print("WEB_TOOLS start %s tool=%s %s" % [OS.get_name(), tool, Engine.get_version_info()["string"]])
	if not TOOLS.has(tool):
		print("WEB_TOOLS unknown tool %s" % tool)
		return
	await get_tree().process_frame
	var node: Node = (load(TOOLS[tool]) as PackedScene).instantiate()
	add_child(node)
