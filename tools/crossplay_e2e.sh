#!/usr/bin/env bash
# Desktop <-> browser cross-play end-to-end check; see tools/crossplay_e2e.py
# (all options there: --pairs desktop:web,web:desktop --mode versus,coop
# --ticks 1800 --no-export ...). Needs python3 + websockets and google-chrome.
exec python3 "$(dirname "$0")/crossplay_e2e.py" "$@"
