#!/usr/bin/env python3
"""HTTPS dev server for the web export (builds/web), reachable from the LAN.

Godot's web build needs a secure context: plain HTTP only counts on
localhost, so a phone or a second PC needs HTTPS. This serves the build over
TLS with a self-signed certificate (made once with openssl, kept in
builds/web-cert/, gitignored with builds/). Browsers warn about it once per
device: accept the warning ("Advanced" -> proceed).

  python3 tools/serve_web.py                # https://<every local IP>:8443/
  python3 tools/serve_web.py --port 9000 --dir builds/web
  python3 tools/serve_web.py --regen-cert   # after the machine's IP changed
  python3 tools/serve_web.py --no-signal    # no room-code signaling
  python3 tools/serve_web.py --no-compress  # raw files, no background work

Online (room codes): the page's default signaling server is its own origin +
/signal (Tuning.net.signaling_path), so this server forwards WebSocket
upgrades on /signal to a local server/signaling_server.py (127.0.0.1:8765,
started here unless one already listens there). One port, one certificate:
nothing else to accept on a phone or a second PC.

Also sends cross-origin isolation headers (COOP/COEP), so a threaded web
export would work too, and no-cache so a fresh export shows on reload.

Compression: the engine .wasm is ~40 MB raw, ~7 MB as Brotli. A background
thread writes index.wasm.gz/.br (same for .pck, .js) next to the export at
startup and after each re-export; until they exist the raw files are served,
so the first load after an export can still be slow (gzip takes seconds,
Brotli about 90 s). Brotli needs `pip install brotli`; without it, gzip only.
"""

import argparse
import atexit
import functools
import gzip
import http.server
import os
import re
import select
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import brotli
except ImportError:
    brotli = None

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "builds" / "web"
CERT_DIR = ROOT / "builds" / "web-cert"
DEFAULT_PORT = 8443
CERT_DAYS = 825  # longest validity Apple platforms accept for a TLS cert
SIGNAL_PATH = "/signal"  # Tuning.net.signaling_path
SIGNAL_PORT = 8765  # server/signaling_server.py default
SIGNAL_SCRIPT = ROOT / "server" / "signaling_server.py"
SIGNAL_START_WAIT = 5.0  # seconds for a started signaling server to listen
PIPE_CHUNK = 65536
COMPRESSIBLE = (".wasm", ".pck", ".js")
GZIP_LEVEL = 9
BROTLI_QUALITY = 11
BROTLI_WINDOW = 24  # the format's largest; the .wasm is far bigger than the default
# Quiet time before compressing a file. Writes within one mtime tick of a read
# would otherwise pass as fresh with truncated contents; a write after this
# always moves the mtime, so it leaves the sidecar stale instead.
SETTLE_SECONDS = 2.0
# Content-Encoding -> sidecar suffix, best first. Gzip is the one built first.
ENCODINGS = {"br": ".br", "gzip": ".gz"} if brotli else {"gzip": ".gz"}


def local_ips() -> list[str]:
    ips = {"127.0.0.1"}
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, check=True).stdout
        ips.update(a for a in out.split() if ":" not in a)
    except (OSError, subprocess.CalledProcessError):
        pass
    # Fallback / extra: the address used for the default route (no packet is sent).
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    return sorted(ips)


def make_cert(cert: Path, key: Path, ips: list[str]) -> None:
    CERT_DIR.mkdir(parents=True, exist_ok=True)
    names = ["localhost"] + ([socket.gethostname()] if socket.gethostname() else [])
    san = ",".join([f"DNS:{n}" for n in names] + [f"IP:{ip}" for ip in ips])
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", str(CERT_DAYS),
        "-subj", "/CN=God Hand Tenkaichi dev server",
        "-addext", f"subjectAltName={san}",
    ], check=True, capture_output=True)
    print(f"Made a self-signed certificate for {san}", flush=True)


def sidecar_of(raw: Path, suffix: str) -> Path:
    return raw.with_name(raw.name + suffix)


def is_fresh(raw: Path, suffix: str) -> bool:
    """A sidecar carries its source's exact mtime, so one compressed from an
    older export never passes, however late it was written."""
    try:
        return sidecar_of(raw, suffix).stat().st_mtime_ns == raw.stat().st_mtime_ns
    except OSError:
        return False


def compress_file(raw: Path, suffix: str) -> None:
    mtime = raw.stat().st_mtime_ns  # before the read: a change during it stays stale
    data = raw.read_bytes()
    if suffix == ".br":
        out = brotli.compress(data, quality=BROTLI_QUALITY, lgwin=BROTLI_WINDOW)
    else:
        out = gzip.compress(data, GZIP_LEVEL, mtime=0)
    sidecar = sidecar_of(raw, suffix)
    tmp = sidecar.with_name(sidecar.name + ".tmp")
    tmp.write_bytes(out)
    os.utime(tmp, ns=(mtime, mtime))
    os.replace(tmp, sidecar)  # a request never sees a half-written file
    print(f"Compressed {raw.name}: {len(data)} -> {len(out)} bytes ({suffix})", flush=True)


class Precompressor:
    """Keeps the sidecars of `directory` up to date on one background thread."""

    def __init__(self, directory: Path, settle_seconds: float = SETTLE_SECONDS) -> None:
        self.directory = directory
        self.settle_seconds = settle_seconds
        self._lock = threading.Lock()
        self._running = False
        self._dirty = False  # a request arrived since the last scan

    def pending(self) -> list[tuple[Path, str]]:
        """(raw file, suffix) of every missing or stale sidecar, cheap ones first."""
        try:
            raws = [p for p in sorted(self.directory.iterdir()) if p.name.endswith(COMPRESSIBLE)]
        except OSError:
            return []
        return [(raw, suffix) for suffix in reversed(ENCODINGS.values()) for raw in raws
                if not is_fresh(raw, suffix)]

    def request(self) -> None:
        with self._lock:
            self._dirty = True
            if self._running:
                return
            self._running = True
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self) -> None:
        try:
            self._work()
        except Exception:
            with self._lock:
                self._running = False
            raise

    def _work(self) -> None:
        # One try per file version: a file that can't be compressed, or a
        # sidecar that can't hold its mtime, must not stall or spin the loop.
        attempted: set[tuple[Path, str, int]] = set()
        while True:
            with self._lock:
                self._dirty = False
            for raw, suffix in self.pending():
                try:
                    stat = raw.stat()
                    version = (raw, suffix, stat.st_mtime_ns)
                    if version in attempted:
                        continue
                    if 0 <= time.time() - stat.st_mtime < self.settle_seconds:
                        time.sleep(self.settle_seconds)  # an export may still be writing it
                        break
                    attempted.add(version)
                    compress_file(raw, suffix)
                except OSError as err:
                    print(f"Compression of {raw.name} failed: {err}", file=sys.stderr, flush=True)
                break
            else:
                with self._lock:
                    if not self._dirty:
                        self._running = False
                        return


def accepted_encodings(header: str) -> set[str]:
    names = set()
    for part in header.split(","):
        name, _, params = part.partition(";")
        if not re.fullmatch(r"\s*q=0(\.0*)?\s*", params, re.IGNORECASE):
            names.add(name.strip().lower())
    return names


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".js": "text/javascript",
    }

    signal_port = 0  # 0 = no /signal forwarding
    precompressor: Precompressor | None = None  # None = always the raw files
    sidecar_encoding = ""  # Content-Encoding of the file translate_path picked

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Vary", "Accept-Encoding")
        if self.sidecar_encoding:
            self.send_header("Content-Encoding", self.sidecar_encoding)
        super().end_headers()

    def send_error(self, code: int, *args: str) -> None:
        self.sidecar_encoding = ""  # the error page is plain HTML
        super().send_error(code, *args)

    def translate_path(self, path: str) -> str:
        """Swaps in the best fresh sidecar the client accepts."""
        target = super().translate_path(path)
        self.sidecar_encoding = ""
        if self.precompressor is None or not target.endswith(COMPRESSIBLE):
            return target
        raw = Path(target)
        accepted = accepted_encodings(self.headers.get("Accept-Encoding", ""))
        best = ""
        for encoding, suffix in ENCODINGS.items():
            if is_fresh(raw, suffix):
                if encoding in accepted and not best:
                    best = encoding
            elif raw.is_file():
                self.precompressor.request()
        if not best:
            return target
        self.sidecar_encoding = best
        return str(sidecar_of(raw, ENCODINGS[best]))

    def guess_type(self, path: str) -> str:
        if self.sidecar_encoding:
            path = path.removesuffix(ENCODINGS[self.sidecar_encoding])
        return super().guess_type(path)

    def do_GET(self) -> None:
        if (self.signal_port and self.path.split("?")[0] == SIGNAL_PATH
                and self.headers.get("Upgrade", "").lower() == "websocket"):
            self._forward_websocket()
            return
        super().do_GET()

    def _forward_websocket(self) -> None:
        """Pipe this upgrade request and the socket after it to the local
        signaling server (it does the WebSocket handshake itself)."""
        try:
            up = socket.create_connection(("127.0.0.1", self.signal_port))
        except OSError:
            self.send_error(502, "signaling server not running")
            return
        lines = [f"{self.command} {self.path} {self.request_version}"]
        for k, v in self.headers.items():
            if k.lower() != "x-forwarded-for":
                lines.append(f"{k}: {v}")
        lines.append(f"X-Forwarded-For: {self.client_address[0]}")
        up.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        down = self.connection
        try:
            while True:
                ready = [down] if isinstance(down, ssl.SSLSocket) and down.pending() else []
                if not ready:
                    ready, _, _ = select.select([down, up], [], [])
                for src in ready:
                    data = src.recv(PIPE_CHUNK)
                    if not data:
                        return
                    (up if src is down else down).sendall(data)
        except OSError:
            pass
        finally:
            up.close()
            self.close_connection = True


def listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def start_signaling(port: int) -> bool:
    """Reuse a signaling server already on `port`, else start one (local only,
    trusting our X-Forwarded-For so per-IP limits see the real clients)."""
    if listening(port):
        print(f"Signaling: using the server already on 127.0.0.1:{port}", flush=True)
        return True
    # On every interface: desktop builds elsewhere on the LAN connect to it
    # directly (ws://<ip>:port; they can't use the self-signed wss). Dev only:
    # --trust-proxy lets a LAN client fake its IP for the per-IP limits.
    proc = subprocess.Popen([sys.executable, str(SIGNAL_SCRIPT), "--bind", "0.0.0.0",
                             "--port", str(port), "--trust-proxy"])
    atexit.register(proc.terminate)
    deadline = time.monotonic() + SIGNAL_START_WAIT
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        if listening(port):
            print(f"Signaling: started server/signaling_server.py on port {port}", flush=True)
            return True
        time.sleep(0.1)
    print("Signaling: could not start server/signaling_server.py (pip install websockets?);"
          " room codes won't work", file=sys.stderr, flush=True)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--dir", type=Path, default=DEFAULT_DIR, help="exported web build (index.html)")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--regen-cert", action="store_true", help="make a new certificate (new IPs)")
    ap.add_argument("--no-signal", action="store_true", help=f"don't forward {SIGNAL_PATH} (room codes)")
    ap.add_argument("--signal-port", type=int, default=SIGNAL_PORT,
                    help="local signaling server port (reused if one listens there)")
    ap.add_argument("--no-compress", action="store_true",
                    help="serve raw files only (no background compression skewing a benchmark)")
    args = ap.parse_args()

    web_dir = args.dir.resolve()
    if not (web_dir / "index.html").is_file():
        print(f"No index.html in {web_dir}. Export first:\n"
              '  mkdir -p builds/web && godot --headless --export-release "Web" builds/web/index.html',
              file=sys.stderr)
        return 1

    ips = local_ips()
    cert, key = CERT_DIR / "cert.pem", CERT_DIR / "key.pem"
    if args.regen_cert or not cert.is_file() or not key.is_file():
        make_cert(cert, key, ips)

    if not args.no_signal and start_signaling(args.signal_port):
        Handler.signal_port = args.signal_port

    if not args.no_compress:
        Handler.precompressor = Precompressor(web_dir)
        if Handler.precompressor.pending():
            print("Compressing the build in the background; raw files until it's done.", flush=True)
        if brotli is None:
            print("No brotli module (pip install brotli): gzip only, ~45% larger downloads.", flush=True)
        Handler.precompressor.request()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = http.server.ThreadingHTTPServer((args.bind, args.port),
                                             functools.partial(Handler, directory=str(web_dir)))
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

    print(f"Serving {web_dir} over HTTPS (Ctrl+C to stop):", flush=True)
    for ip in ["localhost"] + [ip for ip in ips if ip != "127.0.0.1"]:
        print(f"  https://{ip}:{args.port}/", flush=True)
    print("Self-signed certificate: accept the browser warning once per device.", flush=True)
    if Handler.signal_port:
        print(f"Room codes: the page uses wss://<this address>:{args.port}{SIGNAL_PATH} by itself.", flush=True)
        lan = [ip for ip in ips if ip != "127.0.0.1"]
        print("  Desktop builds on another machine: Settings > Online > Signaling server = "
              + " or ".join(f"ws://{ip}:{args.signal_port}" for ip in lan or ["127.0.0.1"]), flush=True)
    # SIGTERM too (not only Ctrl+C), so the signaling server we started stops.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
