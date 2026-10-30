#!/usr/bin/env bash
# Runs tools/frame_probe.tscn in the web build, in Chrome, and prints its
# FRAME_PROBE lines (frame spikes per combat event, per-event costs,
# micro-benchmarks). Web-only slowdowns (WASM GDScript, WebGL2, Web Audio)
# never show in the desktop/headless tests; this is how to measure them.
#   tools/web_probe.sh                       # mode=fight
#   tools/web_probe.sh mode=events reps=3
#   tools/web_probe.sh mode=bench
#   NO_EXPORT=1 tools/web_probe.sh ...       # reuse builds/web-probe/
# Exports the "Web Probe" preset (feature tag web_probe makes the probe the
# main scene; tools/ included) to builds/web-probe/, serves it with
# tools/serve_web.py on https://localhost:$PORT (default 8443, localhost
# only) and opens it in a fresh Chrome profile on $DISPLAY (a real GPU:
# headless Chrome would measure a software rasterizer). Needs the 4.7.2 web
# export templates and google-chrome (or CHROME=<binary>).
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/joallace/opt/Godot_v4.7.2-stable_linux.x86_64}"
CHROME="${CHROME:-google-chrome}"
PORT="${PORT:-8443}"
LIMIT="${LIMIT:-300}"  # seconds before giving up
OUT=builds/web-probe
LOG="$OUT/chrome.log"

if [[ -z "${NO_EXPORT:-}" ]]; then
	mkdir -p "$OUT"
	timeout 300 "$GODOT" --headless --export-release "Web Probe" "$OUT/index.html" >"$OUT/export.log" 2>&1 \
		|| { echo "export failed, see $OUT/export.log"; exit 1; }
fi
QUERY="$(IFS='&'; echo "$*")"
PROFILE="$(mktemp -d)"
python3 tools/serve_web.py --port "$PORT" --bind 127.0.0.1 --dir "$OUT" --no-compress >"$OUT/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; pkill -f "user-data-dir=$PROFILE" 2>/dev/null; rm -rf "$PROFILE"' EXIT
sleep 2
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
	--autoplay-policy=no-user-gesture-required --ignore-certificate-errors \
	--enable-logging=stderr --v=0 --window-size=1280,720 \
	"https://localhost:$PORT/index.html?$QUERY" >"$LOG" 2>&1 &
for _ in $(seq "$LIMIT"); do
	grep -q "FRAME_PROBE DONE" "$LOG" && break
	sleep 1
done
grep -o 'FRAME_PROBE.*' "$LOG" | sed 's/", source: .*//'
grep -q "FRAME_PROBE DONE" "$LOG" || { echo "no FRAME_PROBE DONE within ${LIMIT}s, see $LOG"; exit 1; }
