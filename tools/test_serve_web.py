"""Tests for tools/serve_web.py (pre-compressed responses).

  python3 -m unittest tools/test_serve_web.py

Serves a temp dir over plain HTTP on an ephemeral port per test.
"""

import functools
import gzip
import http.client
import http.server
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import serve_web as sw  # noqa: E402

WASM = b"\0asm" + b"compressible engine bytes " * 4000
HTML = b"<html>" + b"page " * 1000
WAIT_SECONDS = 10.0


class ServeTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.wasm = self.dir / "index.wasm"
        self.wasm.write_bytes(WASM)
        (self.dir / "index.html").write_bytes(HTML)
        self.pre = sw.Precompressor(self.dir, settle_seconds=0.0)
        self.serve(self.pre)

    def serve(self, pre: "sw.Precompressor | None") -> None:
        handler = type("TestHandler", (sw.Handler,), {
            "precompressor": pre,
            "log_message": lambda *_: None,
        })
        self.server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(handler, directory=str(self.dir)))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def get(self, path: str, accept: str = "gzip, br", method: str = "GET",
            **headers: str) -> tuple[http.client.HTTPResponse, bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1])
        self.addCleanup(conn.close)
        conn.request(method, path, headers={"Accept-Encoding": accept, **headers})
        resp = conn.getresponse()
        return resp, resp.read()

    def precompress(self) -> None:
        self.pre.request()
        deadline = time.monotonic() + WAIT_SECONDS
        while self.pre.pending() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.pre.pending(), [])

    def test_gzip_when_the_client_takes_only_gzip(self) -> None:
        self.precompress()
        resp, body = self.get("/index.wasm", "gzip")
        self.assertEqual(resp.getheader("Content-Encoding"), "gzip")
        self.assertEqual(resp.getheader("Content-Type"), "application/wasm")
        self.assertEqual(int(resp.getheader("Content-Length")), len(body))
        self.assertLess(len(body), len(WASM))
        self.assertEqual(gzip.decompress(body), WASM)
        self.assertIn("Accept-Encoding", resp.getheader("Vary"))

    @unittest.skipIf(sw.brotli is None, "brotli module not installed")
    def test_brotli_preferred(self) -> None:
        self.precompress()
        resp, body = self.get("/index.wasm")
        self.assertEqual(resp.getheader("Content-Encoding"), "br")
        self.assertEqual(resp.getheader("Content-Type"), "application/wasm")
        self.assertEqual(sw.brotli.decompress(body), WASM)

    def test_raw_when_no_encoding_is_accepted(self) -> None:
        self.precompress()
        for accept in ("identity", "gzip;q=0, br;q=0.0"):
            resp, body = self.get("/index.wasm", accept)
            self.assertIsNone(resp.getheader("Content-Encoding"), accept)
            self.assertEqual(body, WASM, accept)

    def test_raw_before_compression_finished(self) -> None:
        resp, body = self.get("/index.wasm")
        self.assertIsNone(resp.getheader("Content-Encoding"))
        self.assertEqual(body, WASM)

    def test_small_page_files_stay_raw(self) -> None:
        self.precompress()
        resp, body = self.get("/index.html")
        self.assertIsNone(resp.getheader("Content-Encoding"))
        self.assertEqual(body, HTML)

    def test_reexport_never_serves_the_old_build(self) -> None:
        self.precompress()
        fresh = b"\0asm" + b"a new export " * 4000
        self.wasm.write_bytes(fresh)
        os.utime(self.wasm, ns=(1, 1))  # any mtime change counts, even backwards
        resp, body = self.get("/index.wasm", "gzip")
        self.assertIsNone(resp.getheader("Content-Encoding"))
        self.assertEqual(body, fresh)
        self.precompress()  # that request already started it; this waits
        resp, body = self.get("/index.wasm", "gzip")
        self.assertEqual(resp.getheader("Content-Encoding"), "gzip")
        self.assertEqual(gzip.decompress(body), fresh)

    def test_head_matches_get(self) -> None:
        self.precompress()
        resp, body = self.get("/index.wasm", "gzip", method="HEAD")
        self.assertEqual(body, b"")
        self.assertEqual(resp.getheader("Content-Encoding"), "gzip")
        self.assertLess(int(resp.getheader("Content-Length")), len(WASM))

    def test_not_modified(self) -> None:
        self.precompress()
        first, _ = self.get("/index.wasm", "gzip")
        resp, body = self.get("/index.wasm", "gzip",
                              **{"If-Modified-Since": first.getheader("Last-Modified")})
        self.assertEqual(resp.status, 304)
        self.assertEqual(body, b"")

    def test_recent_write_waits_to_settle(self) -> None:
        settle = 0.3
        self.pre.settle_seconds = settle
        self.pre.request()
        time.sleep(settle / 3)
        self.assertFalse(sw.sidecar_of(self.wasm, ".gz").exists())
        self.precompress()
        self.assertTrue(sw.is_fresh(self.wasm, ".gz"))

    def test_unreadable_entry_does_not_block_the_rest(self) -> None:
        (self.dir / "a.js").mkdir()  # sorts first; compressing it always fails
        self.pre.request()
        deadline = time.monotonic() + WAIT_SECONDS
        while not sw.is_fresh(self.wasm, ".gz") and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(sw.is_fresh(self.wasm, ".gz"))

    def test_sidecar_that_cannot_keep_its_mtime_does_not_spin(self) -> None:
        calls = []
        original = sw.compress_file
        def lossy(raw: Path, suffix: str) -> None:
            calls.append(suffix)
            original(raw, suffix)
            os.utime(sw.sidecar_of(raw, suffix), ns=(1, 1))
        sw.compress_file = lossy
        self.addCleanup(setattr, sw, "compress_file", original)
        self.pre.request()
        deadline = time.monotonic() + WAIT_SECONDS
        while self.pre._running and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertFalse(self.pre._running)
        self.assertEqual(len(calls), len(self.pre.pending()))

    def test_request_during_final_scan_is_not_lost(self) -> None:
        self.precompress()
        original = self.pre.pending
        def export_lands_after_scan() -> list[tuple[Path, str]]:
            work = original()
            if not work and not self.wasm.with_name("b.wasm").exists():
                self.wasm.with_name("b.wasm").write_bytes(WASM)
                self.pre.request()
            return work
        self.pre.pending = export_lands_after_scan
        self.pre.request()
        deadline = time.monotonic() + WAIT_SECONDS
        while original() and time.monotonic() < deadline or self.pre._running:
            time.sleep(0.01)
        self.assertEqual(original(), [])

    def test_error_page_has_no_content_encoding(self) -> None:
        self.precompress()
        real_open = sw.http.server.SimpleHTTPRequestHandler.send_head
        def fail_after_translate(handler: sw.Handler) -> None:
            handler.translate_path(handler.path)
            handler.send_error(404)
        sw.http.server.SimpleHTTPRequestHandler.send_head = fail_after_translate
        self.addCleanup(setattr, sw.http.server.SimpleHTTPRequestHandler, "send_head", real_open)
        resp, _ = self.get("/index.wasm", "gzip")
        self.assertEqual(resp.status, 404)
        self.assertIsNone(resp.getheader("Content-Encoding"))

    def test_accept_encoding_q_is_case_insensitive(self) -> None:
        self.assertEqual(sw.accepted_encodings("gzip;Q=0, br;q=0.5"), {"br"})

    def test_disabled_serves_raw(self) -> None:
        self.precompress()
        self.serve(None)
        resp, body = self.get("/index.wasm")
        self.assertIsNone(resp.getheader("Content-Encoding"))
        self.assertEqual(body, WASM)


if __name__ == "__main__":
    unittest.main()
