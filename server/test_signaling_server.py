"""Tests for server/signaling_server.py (protocol v1, docs/web_online.md).

  python3 -m unittest server/test_signaling_server.py

Starts the server in-process on an ephemeral port per test.
"""

import asyncio
import base64
import dataclasses
import hashlib
import hmac
import json
import logging
import sys
import time
import unittest
import urllib.request
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed

sys.path.insert(0, str(Path(__file__).resolve().parent))
import signaling_server as ss  # noqa: E402

logging.getLogger("ght.signal").setLevel(logging.CRITICAL)

GAME = "1:abcdef"
RECV_TIMEOUT = 2.0
SECRET = "test-secret-do-not-leak"
OFFER = {"type": "offer", "sdp": "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"}
CANDIDATE = {"type": "candidate", "mid": "0", "index": 0, "sdp": "candidate:1 1 udp 1 10.0.0.1 9 typ host"}


class Base(unittest.IsolatedAsyncioTestCase):
    overrides: dict = {}

    async def asyncSetUp(self):
        cfg = ss.Config(bind="127.0.0.1", port=0, ping_interval=0, sweep_interval=0.05)
        cfg = dataclasses.replace(cfg, **self.overrides)
        self.server = ss.SignalingServer(cfg)
        await self.server.start()
        self.url = f"ws://127.0.0.1:{self.server.port}"
        self.sockets = []

    async def asyncTearDown(self):
        for ws in self.sockets:
            await ws.close()
        await self.server.stop()

    async def connect(self):
        ws = await websockets.connect(self.url)
        self.sockets.append(ws)
        return ws

    async def send(self, ws, msg):
        await ws.send(json.dumps(msg))

    async def recv(self, ws):
        return json.loads(await asyncio.wait_for(ws.recv(), RECV_TIMEOUT))

    async def assert_closed(self, ws, code=None):
        with self.assertRaises(ConnectionClosed):
            while True:
                await asyncio.wait_for(ws.recv(), RECV_TIMEOUT)
        if code is not None:
            self.assertEqual(ws.close_code, code)

    async def host(self, max_guests=3, game=GAME):
        ws = await self.connect()
        await self.send(ws, {"op": "host", "game": game, "max_guests": max_guests})
        msg = await self.recv(ws)
        self.assertEqual(msg["op"], "hosted", msg)
        return ws, msg

    async def join(self, code, game=GAME):
        ws = await self.connect()
        await self.send(ws, {"op": "join", "room": code, "game": game})
        return ws, await self.recv(ws)


class ProtocolTest(Base):
    async def test_host_join_relay_both_ways(self):
        host, hosted = await self.host()
        code = hosted["room"]
        self.assertEqual(hosted["peer"], 1)
        self.assertEqual(len(code), ss.ROOM_CODE_LENGTH)
        self.assertTrue(all(c in ss.ROOM_CODE_ALPHABET for c in code))
        self.assertEqual(hosted["ice_servers"], [{"urls": ["stun:stun.l.google.com:19302"]}])

        guest, joined = await self.join(code)
        self.assertEqual(joined, {"op": "joined", "room": code, "peer": 2,
                                  "ice_servers": hosted["ice_servers"]})
        self.assertEqual(await self.recv(host), {"op": "peer_joined", "peer": 2})

        await self.send(host, {"op": "signal", "to": 2, "data": OFFER})
        self.assertEqual(await self.recv(guest), {"op": "signal", "from": 1, "data": OFFER})
        await self.send(guest, {"op": "signal", "to": 1, "data": CANDIDATE})
        self.assertEqual(await self.recv(host), {"op": "signal", "from": 2, "data": CANDIDATE})
        await self.send(host, {"op": "signal", "to": 2, "data": CANDIDATE})
        self.assertEqual(await self.recv(guest), {"op": "signal", "from": 1, "data": CANDIDATE})

    async def test_sids_in_join_order_never_reused(self):
        host, hosted = await self.host(max_guests=3)
        g2, j2 = await self.join(hosted["room"])
        g3, j3 = await self.join(hosted["room"])
        self.assertEqual((j2["peer"], j3["peer"]), (2, 3))
        await g2.close()
        msgs = [await self.recv(host) for _ in range(3)]
        self.assertEqual(msgs, [{"op": "peer_joined", "peer": 2}, {"op": "peer_joined", "peer": 3},
                                {"op": "peer_left", "peer": 2}])
        g4, j4 = await self.join(hosted["room"])
        self.assertEqual(j4["peer"], 4)

    async def test_ping_pong(self):
        ws = await self.connect()
        await self.send(ws, {"op": "ping"})
        self.assertEqual(await self.recv(ws), {"op": "pong"})

    async def test_case_insensitive_code(self):
        _, hosted = await self.host()
        _, joined = await self.join(hosted["room"].lower())
        self.assertEqual(joined["op"], "joined")
        self.assertEqual(joined["room"], hosted["room"])

    async def test_version_mismatch(self):
        _, hosted = await self.host()
        guest, msg = await self.join(hosted["room"], game="2:abcdef")
        self.assertEqual((msg["op"], msg["code"]), ("error", "version_mismatch"))
        await self.assert_closed(guest)

    async def test_room_not_found(self):
        guest, msg = await self.join("ZZZZZZ")
        self.assertEqual((msg["op"], msg["code"]), ("error", "room_not_found"))
        self.assertIsInstance(msg["message"], str)
        await self.assert_closed(guest)

    async def test_room_full(self):
        host, hosted = await self.host(max_guests=1)
        _, j = await self.join(hosted["room"])
        self.assertEqual(j["op"], "joined")
        guest, msg = await self.join(hosted["room"])
        self.assertEqual(msg["code"], "room_full")
        await self.assert_closed(guest)

    async def test_guest_may_only_signal_host(self):
        host, hosted = await self.host()
        g2, _ = await self.join(hosted["room"])
        g3, _ = await self.join(hosted["room"])
        await self.send(g2, {"op": "signal", "to": 3, "data": OFFER})
        msg = await self.recv(g2)
        self.assertEqual((msg["op"], msg["code"]), ("error", "bad_request"))
        # Not relayed, and the socket stays usable.
        await self.send(g2, {"op": "ping"})
        self.assertEqual(await self.recv(g2), {"op": "pong"})
        await self.send(g3, {"op": "ping"})
        self.assertEqual(await self.recv(g3), {"op": "pong"})

    async def test_host_signal_unknown_sid(self):
        host, hosted = await self.host()
        await self.send(host, {"op": "signal", "to": 5, "data": OFFER})
        self.assertEqual((await self.recv(host))["code"], "bad_request")
        await self.send(host, {"op": "signal", "to": 1, "data": OFFER})
        self.assertEqual((await self.recv(host))["code"], "bad_request")

    async def test_host_signal_departed_guest_dropped_quietly(self):
        host, hosted = await self.host()
        g2, _ = await self.join(hosted["room"])
        self.assertEqual((await self.recv(host))["op"], "peer_joined")
        await g2.close()
        self.assertEqual(await self.recv(host), {"op": "peer_left", "peer": 2})
        await self.send(host, {"op": "signal", "to": 2, "data": CANDIDATE})
        await self.send(host, {"op": "ping"})
        self.assertEqual(await self.recv(host), {"op": "pong"})

    async def test_signal_before_room_and_garbage(self):
        ws = await self.connect()
        await self.send(ws, {"op": "signal", "to": 1, "data": OFFER})
        self.assertEqual((await self.recv(ws))["code"], "bad_request")
        await ws.send("not json")
        self.assertEqual((await self.recv(ws))["code"], "bad_request")
        await ws.send(b"\x00\x01")
        self.assertEqual((await self.recv(ws))["code"], "bad_request")
        await self.send(ws, {"op": "nope"})
        self.assertEqual((await self.recv(ws))["code"], "bad_request")
        await self.send(ws, {"op": "ping"})
        self.assertEqual(await self.recv(ws), {"op": "pong"})

    async def test_bad_host_request_closes(self):
        ws = await self.connect()
        await self.send(ws, {"op": "host", "game": GAME, "max_guests": 0})
        self.assertEqual((await self.recv(ws))["code"], "bad_request")
        await self.assert_closed(ws)

    async def test_already_in_room(self):
        host, hosted = await self.host()
        await self.send(host, {"op": "join", "room": hosted["room"], "game": GAME})
        self.assertEqual((await self.recv(host))["code"], "already_in_room")
        await self.assert_closed(host)

    async def test_host_disconnect_closes_room(self):
        host, hosted = await self.host()
        g2, _ = await self.join(hosted["room"])
        await host.close()
        self.assertEqual(await self.recv(g2), {"op": "room_closed"})
        await self.assert_closed(g2)
        guest, msg = await self.join(hosted["room"])
        self.assertEqual(msg["code"], "room_not_found")

    async def test_healthz(self):
        def get():
            with urllib.request.urlopen(f"http://127.0.0.1:{self.server.port}/healthz", timeout=2) as r:
                return r.status, r.read()
        status, body = await asyncio.to_thread(get)
        self.assertEqual((status, body), (200, b"ok\n"))


class LimitsTest(Base):
    overrides = {"msg_rate": 1.0, "msg_burst": 5, "max_message_bytes": 1024,
                 "idle_timeout": 0.2, "max_rooms_per_ip": 1, "max_sockets_per_ip": 6}

    async def test_rate_limit(self):
        ws = await self.connect()
        for _ in range(10):
            await self.send(ws, {"op": "ping"})
        replies = []
        with self.assertRaises(ConnectionClosed):
            while True:
                replies.append(json.loads(await asyncio.wait_for(ws.recv(), RECV_TIMEOUT)))
        self.assertEqual(replies[:5], [{"op": "pong"}] * 5)
        self.assertEqual(replies[5]["code"], "rate_limited")
        self.assertEqual(ws.close_code, ss.CLOSE_POLICY)

    async def test_oversize_message(self):
        host, hosted = await self.host()
        await self.send(host, {"op": "signal", "to": 2, "data": {"sdp": "x" * 2048}})
        await self.assert_closed(host, 1009)

    async def test_idle_timeout(self):
        ws = await self.connect()
        await self.assert_closed(ws, ss.CLOSE_IDLE)

    async def test_hosting_is_not_idle(self):
        host, _ = await self.host()
        await asyncio.sleep(0.4)
        await self.send(host, {"op": "ping"})
        self.assertEqual(await self.recv(host), {"op": "pong"})

    async def test_rooms_per_ip(self):
        await self.host()
        ws = await self.connect()
        await self.send(ws, {"op": "host", "game": GAME, "max_guests": 1})
        self.assertEqual((await self.recv(ws))["code"], "rate_limited")
        await self.assert_closed(ws)

    async def test_sockets_per_ip(self):
        for _ in range(6):
            await self.connect()
        ws = await self.connect()
        self.assertEqual((await self.recv(ws))["code"], "rate_limited")
        await self.assert_closed(ws, ss.CLOSE_POLICY)


class ServerFullTest(Base):
    overrides = {"max_rooms": 1}

    async def test_server_full(self):
        await self.host()
        ws = await self.connect()
        await self.send(ws, {"op": "host", "game": GAME, "max_guests": 1})
        self.assertEqual((await self.recv(ws))["code"], "server_full")
        await self.assert_closed(ws)


class LifetimeTest(Base):
    overrides = {"room_lifetime": 0.3}

    async def test_room_lifetime(self):
        host, hosted = await self.host()
        g2, _ = await self.join(hosted["room"])
        self.assertEqual((await self.recv(host))["op"], "peer_joined")
        self.assertEqual(await self.recv(g2), {"op": "room_closed"})
        self.assertEqual(await self.recv(host), {"op": "room_closed"})
        await self.assert_closed(host, ss.CLOSE_ROOM_EXPIRED)
        self.assertEqual(self.server.rooms, {})
        self.assertEqual(self.server.rooms_per_ip, {})


class TurnTest(Base):
    overrides = {"turn_urls": ["turn:turn.example.com:3478?transport=udp", "turns:turn.example.com:5349"],
                 "turn_secret": SECRET, "turn_ttl": 600}

    async def test_turn_credentials(self):
        before = int(time.time())
        host, hosted = await self.host()
        guest, joined = await self.join(hosted["room"])
        for msg, sid in ((hosted, 1), (joined, 2)):
            stun, turn = msg["ice_servers"]
            self.assertEqual(stun, {"urls": ["stun:stun.l.google.com:19302"]})
            self.assertEqual(turn["urls"], self.overrides["turn_urls"])
            expiry, label = turn["username"].split(":", 1)
            self.assertTrue(before + 600 <= int(expiry) <= int(time.time()) + 600)
            self.assertEqual(label, f"{hosted['room']}-{sid}")
            want = base64.b64encode(hmac.new(SECRET.encode(), turn["username"].encode(),
                                             hashlib.sha1).digest()).decode()
            self.assertEqual(turn["credential"], want)
            self.assertNotIn(SECRET, json.dumps(msg))

    def test_credential_known_vector(self):
        user, cred = ss.turn_credential("north", "ABCDEF-1", 3600, now=1700000000)
        self.assertEqual(user, "1700003600:ABCDEF-1")
        self.assertEqual(cred, base64.b64encode(
            hmac.new(b"north", b"1700003600:ABCDEF-1", hashlib.sha1).digest()).decode())


class ConfigTest(unittest.TestCase):
    def test_env_and_cli(self):
        env = {"GHT_SIGNAL_PORT": "9000", "GHT_STUN_URLS": "stun:a:1, stun:b:2",
               "GHT_TURN_SECRET": "s", "GHT_SIGNAL_TRUST_PROXY": "yes", "GHT_TURN_TTL": "60"}
        cfg = ss.config_from([], env)
        self.assertEqual((cfg.port, cfg.stun_urls, cfg.turn_secret, cfg.trust_proxy, cfg.turn_ttl),
                         (9000, ["stun:a:1", "stun:b:2"], "s", True, 60))
        cfg = ss.config_from(["--port", "9001", "--trust-proxy", "false", "--stun-urls", "",
                              "--msg-rate", "2.5", "--dev-cert"], env)
        self.assertEqual((cfg.port, cfg.trust_proxy, cfg.stun_urls, cfg.msg_rate, cfg.dev_cert),
                         (9001, False, [], 2.5, True))

    def test_no_turn_without_secret(self):
        cfg = ss.Config(turn_urls=["turn:x:3478"])
        self.assertEqual(ss.ice_servers(cfg, "", "L"), [{"urls": ["stun:stun.l.google.com:19302"]}])


if __name__ == "__main__":
    logging.basicConfig(level=logging.CRITICAL)
    unittest.main()
