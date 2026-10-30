#!/usr/bin/env bash
# Runs a headless tool (tools/web_tools.tscn) in the web build, in Chrome,
# and prints its console lines:
#   tools/web_tools.sh tool=replay                # cross-runtime determinism:
#       plays tools/replays/*.ghr (recorded on desktop), REPLAY_HASH lines
#   tools/web_tools.sh tool=bench mode=coop humans=2 enemies=4 driver=0
#       tools/net_bench in WASM, NET_BENCH lines
#   tools/web_tools.sh tool=net_peer role=guest code=ABCDEF signal=ws://127.0.0.1:18765
#       one peer of a WebRTC match, NET_PEER lines (tools/crossplay_e2e.sh
#       runs both peers and compares them)
#   NO_EXPORT=1 tools/web_tools.sh ...            # reuse builds/web-tools/
# Exports the "Web Tools" preset (feature tag web_tools makes web_tools.tscn
# the main scene; tools/ and tools/replays/*.ghr included) to
# builds/web-tools/, serves it over HTTP on 127.0.0.1:$PORT (default 18000;
# localhost is a secure context) and opens it in headless Chrome with a
# throwaway profile (HEADLESS=0: a normal window on $DISPLAY). Neither tool
# renders anything, so headless Chrome's software WebGL is fine; the sim
# cost it measures is WASM GDScript on this CPU.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/joallace/opt/Godot_v4.7.2-stable_linux.x86_64}"
CHROME="${CHROME:-google-chrome}"
PORT="${PORT:-18000}"
LIMIT="${LIMIT:-900}"  # seconds before giving up
OUT=builds/web-tools
LOG="${LOG:-$OUT/chrome.log}"

if [[ -z "${NO_EXPORT:-}" ]]; then
	mkdir -p "$OUT"
	timeout 300 "$GODOT" --headless --export-release "Web Tools" "$OUT/index.html" >"$OUT/export.log" 2>&1 \
		|| { echo "export failed, see $OUT/export.log"; exit 1; }
fi
QUERY="$(IFS='&'; echo "$*")"
PROFILE="$(mktemp -d)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$OUT" >"$OUT/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; pkill -f "user-data-dir=$PROFILE" 2>/dev/null; sleep 1; rm -rf "$PROFILE"' EXIT
sleep 1
HEADLESS_ARGS=(--headless=new --use-angle=swiftshader --enable-unsafe-swiftshader)
[[ "${HEADLESS:-1}" == "0" ]] && HEADLESS_ARGS=()
"$CHROME" "${HEADLESS_ARGS[@]}" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
	--disable-background-timer-throttling --disable-renderer-backgrounding \
	--enable-logging=stderr --v=0 --window-size=1280,720 \
	"http://127.0.0.1:$PORT/index.html?$QUERY" >"$LOG" 2>&1 &
DONE_RE='(REPLAY_HASH|NET_BENCH|NET_PEER) DONE|WEB_TOOLS unknown'
for _ in $(seq "$LIMIT"); do
	grep -qE "$DONE_RE" "$LOG" && break
	sleep 1
done
# net_peer keeps feeding the far peer for a few seconds after DONE.
[[ "$*" == *tool=net_peer* ]] && sleep 5
grep -oE '(WEB_TOOLS|REPLAY_HASH|NET_BENCH|NET_PEER|SCRIPT ERROR|ERROR:).*' "$LOG" | sed 's/", source: .*//'
grep -q "REPLAY_HASH DONE MISMATCH\|NET_BENCH DONE FAIL\|NET_PEER DONE FAIL" "$LOG" && exit 1
grep -qE "$DONE_RE" "$LOG" || { echo "no DONE line within ${LIMIT}s, see $LOG"; exit 1; }
exit 0
