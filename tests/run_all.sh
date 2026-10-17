#!/usr/bin/env bash
# Runs every headless test scene in tests/ and fails if any exits non-zero or
# prints a SCRIPT ERROR. Tests are scenes (not --script) so autoloads exist.
#   GODOT=/path/to/godot tests/run_all.sh            # all tests
#   tests/run_all.sh combat_test                     # just one (name filter)
set -u
GODOT="${GODOT:-/home/joallace/opt/Godot_v4.7.2-stable_linux.x86_64}"
cd "$(dirname "$0")/.."

timeout 180 "$GODOT" --headless --import >/dev/null 2>&1

fail=0
for scene in tests/*.tscn; do
	name="$(basename "$scene" .tscn)"
	[[ -n "${1:-}" && "$name" != *"$1"* ]] && continue
	out="$(timeout 120 "$GODOT" --headless "res://$scene" 2>&1)"
	code=$?
	out="$(grep -vi adwaita <<<"$out")"
	if [[ $code -ne 0 ]] || grep -qE "SCRIPT ERROR|^FAIL|[^_]FAIL\b" <<<"$out"; then
		echo "FAIL $name (exit $code)"
		echo "$out" | grep -E "SCRIPT ERROR|FAIL|at: " | head -30
		fail=1
	else
		echo "PASS $name"
	fi
done
exit $fail
