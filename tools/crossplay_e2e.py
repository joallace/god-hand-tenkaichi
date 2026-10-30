#!/usr/bin/env python3
"""Desktop <-> browser cross-play end-to-end check (docs/web_online.md,
"Cross-play end-to-end check").

Starts the real signaling server (server/signaling_server.py), exports the
"Web Tools" preset to builds/web-tools/ and serves it on 127.0.0.1 (a
secure context, so the page may use ws://127.0.0.1), then for each
direction runs tools/net_peer (one peer of a Session + RollbackDriver match
over WebRTC) as host and guest: a native headless Godot and the WASM build
in headless Chrome. The host prints its room code, the guest joins by it,
both print their confirmed checkpoint hashes; the verdict compares them.

  tools/crossplay_e2e.sh                         # both directions, versus
  tools/crossplay_e2e.sh --mode coop --ticks 1800
  tools/crossplay_e2e.sh --pairs desktop:web     # host:guest pairs
  tools/crossplay_e2e.sh --no-export             # reuse builds/web-tools/
  HEADLESS=0 tools/crossplay_e2e.sh              # Chrome in a window on $DISPLAY

Exit 0 when every direction passes. Logs: builds/web-tools/e2e/.
"""
import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.environ.get("GODOT", "/home/joallace/opt/Godot_v4.7.2-stable_linux.x86_64")
CHROME = os.environ.get("CHROME", "google-chrome")
OUT = os.path.join(ROOT, "builds", "web-tools")
LOGS = os.path.join(OUT, "e2e")
LINE_RE = re.compile(r"NET_PEER [^\"\r\n]*")


def wait_port(port, limit=15.0):
    end = time.time() + limit
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False


class Peer:
    """One net_peer process (desktop Godot or Chrome) and its NET_PEER lines."""

    def __init__(self, kind, role, args, log_path, http_port):
        self.kind = kind
        self.role = role
        self.log_path = log_path
        self.profile = None
        query = ["tool=net_peer", "role=" + role] + ["%s=%s" % kv for kv in args.items()]
        if kind == "desktop":
            cmd = ["timeout", "600", GODOT, "--headless", "res://tools/web_tools.tscn", "--"] + query
        else:
            self.profile = tempfile.mkdtemp(prefix="crossplay-chrome-")
            cmd = [CHROME]
            if os.environ.get("HEADLESS", "1") != "0":
                cmd += ["--headless=new", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
            cmd += ["--user-data-dir=" + self.profile, "--no-first-run", "--no-default-browser-check",
                    "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                    "--disable-backgrounding-occluded-windows", "--enable-logging=stderr", "--v=0",
                    "--window-size=1280,720"]
            cmd += os.environ.get("CHROME_FLAGS", "").split()
            cmd.append("http://127.0.0.1:%d/index.html?%s" % (http_port, "&".join(query)))
        self.log = open(log_path, "w")
        # Own process group: Chrome's helpers die with it (killpg), nothing else does.
        self.proc = subprocess.Popen(cmd, cwd=ROOT, stdout=self.log, stderr=subprocess.STDOUT,
                                     start_new_session=True)

    def lines(self):
        with open(self.log_path, errors="replace") as f:
            return [m.group(0).strip() for m in LINE_RE.finditer(f.read())]

    def find(self, prefix):
        for line in self.lines():
            if line.startswith(prefix):
                return line
        return None

    def done(self):
        return self.find("NET_PEER DONE")

    def hashes(self):
        out = {}
        for line in self.lines():
            p = line.split()
            if len(p) == 4 and p[1] == "HASH":
                out[int(p[2])] = int(p[3])
        return out

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.log.close()
        if self.profile:
            shutil.rmtree(self.profile, ignore_errors=True)


def run_pair(host_kind, guest_kind, a):
    tag = "%s_host-%s_guest-%s" % (a.mode, host_kind, guest_kind)
    args = {"signal": "ws://127.0.0.1:%d" % a.signal_port, "mode": a.mode, "ticks": a.ticks,
            "seed": a.seed, "delay": a.delay}
    print("== %s host, %s guest (%s, %d ticks)" % (host_kind, guest_kind, a.mode, a.ticks), flush=True)
    peers = []
    try:
        host = Peer(host_kind, "host", args, os.path.join(LOGS, tag + "_host.log"), a.http_port)
        peers.append(host)
        code = None
        end = time.time() + a.connect_limit
        while time.time() < end and code is None and host.done() is None:
            line = host.find("NET_PEER CODE")
            code = line.split()[2] if line else None
            time.sleep(0.3)
        if code is None:
            print("FAIL: host printed no room code (%s)" % (host.done() or "timeout"))
            return False
        print("room code %s" % code, flush=True)
        guest = Peer(guest_kind, "guest", dict(args, code=code), os.path.join(LOGS, tag + "_guest.log"),
                     a.http_port)
        peers.append(guest)
        end = time.time() + a.limit
        while time.time() < end:
            if all(p.done() for p in peers):
                break
            if any(not p.alive() and not p.done() for p in peers):
                break
            time.sleep(0.5)
        # Let the lingering peers finish (they keep feeding the far side).
        end = time.time() + 10
        while time.time() < end and any(p.alive() for p in peers):
            time.sleep(0.3)
        ok = True
        for p in peers:
            for line in p.lines():
                if not line.startswith("NET_PEER HASH"):
                    print("  %s/%s: %s" % (p.kind, p.role, line))
            d = p.done()
            if d is None or not d.startswith("NET_PEER DONE OK"):
                ok = False
                print("  %s/%s: no DONE OK (log %s)" % (p.kind, p.role, p.log_path))
        hh, gh = host.hashes(), guest.hashes()
        common = sorted(set(hh) & set(gh))
        bad = [t for t in common if hh[t] != gh[t]]
        expect = a.ticks // 30
        print("  hashes: host %d, guest %d, common %d, mismatched %d %s" % (
            len(hh), len(gh), len(common), len(bad), bad[:5]))
        if bad or len(common) < expect or set(hh) != set(gh):
            ok = False
        # Bulk probe: the host's RESYNC of a checkpoint arrives intact.
        sent, got = host.find("NET_PEER BULK_SENT"), guest.find("NET_PEER BULK ")
        if sent is None or got is None or "match=true" not in got or sent.split()[2:4] != got.split()[2:4]:
            ok = False
            print("  bulk probe failed")
        print("%s: %s host <-> %s guest, %s" % ("PASS" if ok else "FAIL", host_kind, guest_kind, a.mode), flush=True)
        return ok
    finally:
        for p in peers:
            p.stop()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pairs", default="desktop:web,web:desktop", help="host:guest,... (desktop|web)")
    ap.add_argument("--mode", default="versus", help="versus|coop, or a comma list")
    ap.add_argument("--ticks", type=int, default=1800)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--delay", type=int, default=2)
    ap.add_argument("--signal-port", type=int, default=18765)
    ap.add_argument("--http-port", type=int, default=18000)
    ap.add_argument("--connect-limit", type=float, default=90, help="seconds for the host's room code")
    ap.add_argument("--limit", type=float, default=600, help="seconds for a match")
    ap.add_argument("--no-export", action="store_true", help="reuse builds/web-tools/")
    a = ap.parse_args()
    os.makedirs(LOGS, exist_ok=True)
    pairs = [p.split(":") for p in a.pairs.split(",")]
    need_web = any("web" in p for p in pairs)
    procs = []
    try:
        if need_web and not a.no_export:
            print("exporting Web Tools ...", flush=True)
            with open(os.path.join(OUT, "export.log"), "w") as log:
                r = subprocess.run(["timeout", "300", GODOT, "--headless", "--export-release", "Web Tools",
                                    os.path.join(OUT, "index.html")], cwd=ROOT, stdout=log, stderr=log)
            if r.returncode != 0:
                print("export failed, see %s/export.log" % OUT)
                return 1
        sig_log = open(os.path.join(LOGS, "signaling.log"), "w")
        procs.append(subprocess.Popen([sys.executable, os.path.join(ROOT, "server", "signaling_server.py"),
                                       "--bind", "127.0.0.1", "--port", str(a.signal_port)],
                                      stdout=sig_log, stderr=subprocess.STDOUT, start_new_session=True))
        if need_web:
            srv_log = open(os.path.join(LOGS, "http.log"), "w")
            procs.append(subprocess.Popen([sys.executable, "-m", "http.server", str(a.http_port), "--bind",
                                           "127.0.0.1", "--directory", OUT],
                                          stdout=srv_log, stderr=subprocess.STDOUT, start_new_session=True))
        if not wait_port(a.signal_port) or (need_web and not wait_port(a.http_port)):
            print("signaling server / http server did not come up (ports %d, %d in use?)" % (
                a.signal_port, a.http_port))
            return 1
        results = []
        for mode in a.mode.split(","):
            a.mode = mode
            for host_kind, guest_kind in pairs:
                results.append(run_pair(host_kind, guest_kind, a))
        print("CROSSPLAY %s (%d/%d directions passed)" % (
            "PASS" if all(results) else "FAIL", sum(results), len(results)))
        return 0 if all(results) else 1
    finally:
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass


if __name__ == "__main__":
    sys.exit(main())
