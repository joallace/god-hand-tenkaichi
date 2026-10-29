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

Also sends cross-origin isolation headers (COOP/COEP), so a threaded web
export would work too, and no-cache so a fresh export shows on reload.
"""

import argparse
import functools
import http.server
import socket
import ssl
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "builds" / "web"
CERT_DIR = ROOT / "builds" / "web-cert"
DEFAULT_PORT = 8443
CERT_DAYS = 825  # longest validity Apple platforms accept for a TLS cert


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


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".js": "text/javascript",
    }

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--dir", type=Path, default=DEFAULT_DIR, help="exported web build (index.html)")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--regen-cert", action="store_true", help="make a new certificate (new IPs)")
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

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = http.server.ThreadingHTTPServer((args.bind, args.port),
                                             functools.partial(Handler, directory=str(web_dir)))
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

    print(f"Serving {web_dir} over HTTPS (Ctrl+C to stop):", flush=True)
    for ip in ["localhost"] + [ip for ip in ips if ip != "127.0.0.1"]:
        print(f"  https://{ip}:{args.port}/", flush=True)
    print("Self-signed certificate: accept the browser warning once per device.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
