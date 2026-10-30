#!/usr/bin/env python3
"""WebRTC signaling server for God Hand Tenkaichi (protocol v1).

Brokers WebRTC connections between a room's host and its guests and keeps
the room directory. It never carries game packets and holds no game logic.
The protocol is specified in docs/web_online.md ("Signaling protocol (v1)").

  python3 server/signaling_server.py                    # ws://0.0.0.0:8765
  python3 server/signaling_server.py --dev-cert         # wss:// with builds/web-cert/
  python3 server/signaling_server.py --cert c.pem --key k.pem
  python3 server/signaling_server.py --help             # every limit / env var

Every setting has a default in `Config`, an env var (GHT_*) and a CLI flag;
CLI beats env beats default. Works with websockets 12 (legacy API) and 13+
(new asyncio API).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import dataclasses
import hashlib
import hmac
import json
import logging
import os
import secrets
import ssl
import sys
import time
from dataclasses import dataclass, field
from http import HTTPStatus
from pathlib import Path
from typing import Any, Optional

import websockets
from websockets.exceptions import ConnectionClosed

try:  # websockets >= 13: new asyncio implementation.
    from websockets.asyncio.server import serve as _ws_serve
    _NEW_API = True
except ImportError:  # websockets 12: legacy implementation.
    from websockets.server import serve as _ws_serve  # type: ignore[no-redef]
    _NEW_API = False

ROOT = Path(__file__).resolve().parent.parent
DEV_CERT_DIR = ROOT / "builds" / "web-cert"  # written by tools/serve_web.py

PROTOCOL_VERSION = 1
ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I
ROOM_CODE_LENGTH = 6
HOST_SID = 1

# Error codes (contract).
E_BAD_REQUEST = "bad_request"
E_ROOM_NOT_FOUND = "room_not_found"
E_ROOM_FULL = "room_full"
E_VERSION_MISMATCH = "version_mismatch"
E_RATE_LIMITED = "rate_limited"
E_SERVER_FULL = "server_full"
E_ALREADY_IN_ROOM = "already_in_room"

# WebSocket close codes this server uses.
CLOSE_NORMAL = 1000           # after an error on host/join, room closed
CLOSE_POLICY = 1008           # rate limit / per-IP limits
CLOSE_IDLE = 4001             # never hosted or joined in time
CLOSE_ROOM_EXPIRED = 4002     # host's room hit the max lifetime
CLOSE_GUEST_TTL = 4003        # guest stayed on signaling past guest_ttl

log = logging.getLogger("ght.signal")


# --------------------------------------------------------------------------
# Config

def _opt(default: Any, env: str, help: str, **kw: Any) -> Any:
    meta = {"env": env, "help": help}
    if isinstance(default, list):
        return field(default_factory=lambda: list(default), metadata=meta, **kw)
    return field(default=default, metadata=meta, **kw)


@dataclass
class Config:
    """Every server limit and setting. Env var and CLI flag per field."""

    bind: str = _opt("0.0.0.0", "GHT_SIGNAL_BIND", "address to listen on")
    port: int = _opt(8765, "GHT_SIGNAL_PORT", "port to listen on (0 = ephemeral)")
    cert: str = _opt("", "GHT_SIGNAL_CERT", "TLS certificate (PEM) for wss://")
    key: str = _opt("", "GHT_SIGNAL_KEY", "TLS private key (PEM) for wss://")
    dev_cert: bool = _opt(False, "GHT_SIGNAL_DEV_CERT",
                          "use builds/web-cert/{cert,key}.pem from tools/serve_web.py")
    trust_proxy: bool = _opt(False, "GHT_SIGNAL_TRUST_PROXY",
                             "take the client IP from X-Forwarded-For (only behind your own proxy)")
    healthz: bool = _opt(True, "GHT_SIGNAL_HEALTHZ", "answer plain HTTP GET /healthz with 200")
    log_level: str = _opt("INFO", "GHT_SIGNAL_LOG_LEVEL", "DEBUG, INFO, WARNING, ERROR")

    max_message_bytes: int = _opt(16384, "GHT_SIGNAL_MAX_MESSAGE_BYTES",
                                  "largest accepted frame (an SDP offer is ~1-4 KB)")
    msg_rate: float = _opt(20.0, "GHT_SIGNAL_MSG_RATE", "messages/s refilled per socket")
    msg_burst: int = _opt(80, "GHT_SIGNAL_MSG_BURST",
                          "token bucket size per socket (ICE candidates come in bursts)")
    max_sockets: int = _opt(4000, "GHT_SIGNAL_MAX_SOCKETS", "open sockets, whole server")
    max_sockets_per_ip: int = _opt(16, "GHT_SIGNAL_MAX_SOCKETS_PER_IP", "open sockets per IP")
    max_rooms: int = _opt(1000, "GHT_SIGNAL_MAX_ROOMS", "open rooms, whole server")
    max_rooms_per_ip: int = _opt(4, "GHT_SIGNAL_MAX_ROOMS_PER_IP", "open rooms per IP")
    max_guests_cap: int = _opt(7, "GHT_SIGNAL_MAX_GUESTS_CAP", "highest max_guests a host may ask")
    idle_timeout: float = _opt(30.0, "GHT_SIGNAL_IDLE_TIMEOUT",
                               "seconds a socket may stay without hosting/joining")
    room_lifetime: float = _opt(6 * 3600.0, "GHT_SIGNAL_ROOM_LIFETIME", "max seconds a room stays open")
    guest_ttl: float = _opt(120.0, "GHT_SIGNAL_GUEST_TTL",
                            "seconds a guest may stay on signaling after joining (a connected "
                            "guest leaves within ~1 s; this stops sockets that join and never "
                            "connect from filling a room until it expires)")
    close_grace: float = _opt(1.0, "GHT_SIGNAL_CLOSE_GRACE",
                              "seconds a socket gets to close itself after a final message "
                              "(error, room_closed) before the server closes it; Godot's native "
                              "WebSocketPeer drops a frame that arrives together with the close")
    sweep_interval: float = _opt(1.0, "GHT_SIGNAL_SWEEP_INTERVAL",
                                 "seconds between idle/lifetime checks")
    ping_interval: float = _opt(20.0, "GHT_SIGNAL_PING_INTERVAL",
                                "seconds between WebSocket keepalive pings (0 = off)")
    ping_timeout: float = _opt(20.0, "GHT_SIGNAL_PING_TIMEOUT", "seconds to wait for a pong")

    stun_urls: list = _opt(["stun:stun.l.google.com:19302"], "GHT_STUN_URLS",
                           "comma-separated STUN URLs handed to clients (empty = none)")
    turn_urls: list = _opt([], "GHT_TURN_URLS",
                           "comma-separated TURN URLs, e.g. turn:turn.example.com:3478?transport=udp")
    turn_secret: str = _opt("", "GHT_TURN_SECRET",
                            "coturn static-auth-secret (never sent to clients)")
    turn_secret_file: str = _opt("", "GHT_TURN_SECRET_FILE",
                                 "read the TURN secret from this file instead")
    turn_ttl: int = _opt(6 * 3600, "GHT_TURN_TTL", "seconds a TURN credential stays valid")

    def ssl_context(self) -> Optional[ssl.SSLContext]:
        cert, key = self.cert, self.key
        if self.dev_cert and not cert:
            cert, key = str(DEV_CERT_DIR / "cert.pem"), str(DEV_CERT_DIR / "key.pem")
        if not cert:
            return None
        for path in (cert, key):
            if path and not Path(path).is_file():
                hint = " (run tools/serve_web.py once to make the dev cert)" if self.dev_cert else ""
                raise SystemExit(f"TLS file not found: {path}{hint}")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key or None)
        return ctx

    def resolved_turn_secret(self) -> str:
        if self.turn_secret_file:
            return Path(self.turn_secret_file).read_text().strip()
        return self.turn_secret


def _parse_bool(text: str) -> bool:
    t = text.strip().lower()
    if t in ("1", "true", "yes", "on"):
        return True
    if t in ("0", "false", "no", "off", ""):
        return False
    raise ValueError(f"not a boolean: {text!r}")


def _parse_list(text: str) -> list:
    return [s.strip() for s in text.split(",") if s.strip()]


def _converter(f: dataclasses.Field):
    default = f.default if f.default is not dataclasses.MISSING else f.default_factory()  # type: ignore[misc]
    if isinstance(default, bool):
        return _parse_bool
    if isinstance(default, list):
        return _parse_list
    return type(default)


def config_from(argv: Optional[list] = None, environ: Optional[dict] = None) -> Config:
    """Defaults <- env vars <- CLI flags."""
    environ = os.environ if environ is None else environ
    cfg = Config()
    for f in dataclasses.fields(Config):
        env = f.metadata["env"]
        if env in environ:
            setattr(cfg, f.name, _converter(f)(environ[env]))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    for f in dataclasses.fields(Config):
        flag = "--" + f.name.replace("_", "-")
        conv = _converter(f)
        shown = getattr(cfg, f.name)
        if f.name == "turn_secret" and shown:
            shown = "<set>"
        help_text = f"{f.metadata['help']} [env {f.metadata['env']}]"
        if conv is _parse_bool:
            ap.add_argument(flag, dest=f.name, nargs="?", const=True, type=_parse_bool,
                            default=argparse.SUPPRESS, help=help_text + f" (now {shown})")
        else:
            ap.add_argument(flag, dest=f.name, type=conv, default=argparse.SUPPRESS,
                            help=help_text + f" (now {shown!r})")
    args = ap.parse_args(argv)
    for name, value in vars(args).items():
        setattr(cfg, name, value)
    return cfg


# --------------------------------------------------------------------------
# ICE servers / TURN REST credentials

def turn_credential(secret: str, label: str, ttl: int, now: Optional[float] = None) -> tuple[str, str]:
    """coturn use-auth-secret: username "<expiry>:<label>", HMAC-SHA1 base64."""
    expiry = int(time.time() if now is None else now) + ttl
    username = f"{expiry}:{label}"
    digest = hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    return username, base64.b64encode(digest).decode()


def ice_servers(cfg: Config, secret: str, label: str) -> list:
    out: list = []
    if cfg.stun_urls:
        out.append({"urls": list(cfg.stun_urls)})
    if cfg.turn_urls and secret:
        username, credential = turn_credential(secret, label, cfg.turn_ttl)
        out.append({"urls": list(cfg.turn_urls), "username": username, "credential": credential})
    return out


# --------------------------------------------------------------------------
# Websockets 12 / 13+ compatibility

def _request_headers(ws: Any) -> Any:
    if _NEW_API:
        return ws.request.headers
    return ws.request_headers


def _make_process_request(cfg: Config):
    if not cfg.healthz:
        return None
    if _NEW_API:
        def process_request(connection: Any, request: Any):
            if request.path.split("?")[0] == "/healthz":
                return connection.respond(HTTPStatus.OK, "ok\n")
            return None
    else:
        async def process_request(path: str, headers: Any):  # type: ignore[misc]
            if path.split("?")[0] == "/healthz":
                return HTTPStatus.OK, [("Content-Type", "text/plain")], b"ok\n"
            return None
    return process_request


# --------------------------------------------------------------------------
# State

class TokenBucket:
    def __init__(self, rate: float, burst: int) -> None:
        self.rate, self.burst = rate, float(burst)
        self.tokens = float(burst)
        self.stamp = time.monotonic()

    def take(self) -> bool:
        now = time.monotonic()
        self.tokens = min(self.burst, self.tokens + (now - self.stamp) * self.rate)
        self.stamp = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False


class Client:
    def __init__(self, ws: Any, ip: str, cfg: Config) -> None:
        self.ws = ws
        self.ip = ip
        self.bucket = TokenBucket(cfg.msg_rate, cfg.msg_burst)
        self.opened = time.monotonic()
        self.room: Optional[Room] = None
        self.sid = 0
        self.joined = 0.0
        self.closing = False


class Room:
    def __init__(self, code: str, game: str, max_guests: int, host: Client) -> None:
        self.code = code
        self.game = game
        self.max_guests = max_guests
        self.host: Optional[Client] = host
        self.guests: dict[int, Client] = {}
        self.next_sid = HOST_SID + 1
        self.created = time.monotonic()


# --------------------------------------------------------------------------
# Server

class SignalingServer:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.turn_secret = cfg.resolved_turn_secret()
        self.rooms: dict[str, Room] = {}
        self.clients: set[Client] = set()
        self.sockets_per_ip: dict[str, int] = {}
        self.rooms_per_ip: dict[str, int] = {}
        self.port = 0
        self._server: Any = None
        self._sweeper: Optional[asyncio.Task] = None
        self._bg: set[asyncio.Task] = set()

    # ---- lifecycle

    async def start(self) -> None:
        cfg = self.cfg
        ping = cfg.ping_interval if cfg.ping_interval > 0 else None
        tls = cfg.ssl_context()
        self._server = await _ws_serve(
            self._handle, cfg.bind, cfg.port,
            ssl=tls,
            max_size=cfg.max_message_bytes,
            compression=None,
            ping_interval=ping,
            ping_timeout=cfg.ping_timeout if ping else None,
            process_request=_make_process_request(cfg),
        )
        self.port = self._server.sockets[0].getsockname()[1]
        self._sweeper = asyncio.create_task(self._sweep_loop())
        if cfg.turn_urls and not self.turn_secret:
            log.warning("event=config_warning msg=\"TURN URLs set without a secret; TURN not offered\"")
        log.info("event=listening bind=%s port=%d tls=%s turn=%s", cfg.bind, self.port,
                 tls is not None, bool(cfg.turn_urls and self.turn_secret))

    async def stop(self) -> None:
        if self._sweeper:
            self._sweeper.cancel()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        for t in list(self._bg):
            t.cancel()

    async def serve_forever(self) -> None:
        await self.start()
        try:
            await asyncio.Future()
        finally:
            await self.stop()

    # ---- helpers

    def _client_ip(self, ws: Any) -> str:
        if self.cfg.trust_proxy:
            fwd = _request_headers(ws).get("X-Forwarded-For")
            if fwd:
                # The trusted proxy appends the address it saw: take the last hop.
                return fwd.split(",")[-1].strip()
        addr = ws.remote_address
        return str(addr[0]) if addr else "?"

    def _spawn(self, coro: Any) -> None:
        t = asyncio.create_task(coro)
        self._bg.add(t)
        t.add_done_callback(self._bg.discard)

    async def _send(self, client: Client, msg: dict) -> None:
        try:
            await client.ws.send(json.dumps(msg, separators=(",", ":")))
        except ConnectionClosed:
            pass

    async def _close(self, client: Client, code: int, reason: str) -> None:
        client.closing = True
        try:
            if self.cfg.close_grace > 0:
                # Let the client read the last message and close its end.
                try:
                    await asyncio.wait_for(client.ws.wait_closed(), self.cfg.close_grace)
                    return
                except asyncio.TimeoutError:
                    pass
            await client.ws.close(code, reason)
        except ConnectionClosed:
            pass

    async def _error(self, client: Client, code: str, message: str, close: bool = False,
                     close_code: int = CLOSE_NORMAL) -> None:
        await self._send(client, {"op": "error", "code": code, "message": message})
        if close:
            await self._close(client, close_code, code)

    # ---- connection

    async def _handle(self, ws: Any, _path: Any = None) -> None:
        cfg = self.cfg
        ip = self._client_ip(ws)
        client = Client(ws, ip, cfg)
        if len(self.clients) >= cfg.max_sockets:
            log.warning("event=reject reason=max_sockets ip=%s", ip)
            await self._error(client, E_SERVER_FULL, "Server is full, try again later.", True)
            return
        if self.sockets_per_ip.get(ip, 0) >= cfg.max_sockets_per_ip:
            log.warning("event=rate_limited reason=sockets_per_ip ip=%s", ip)
            await self._error(client, E_RATE_LIMITED, "Too many connections from your address.",
                              True, CLOSE_POLICY)
            return
        self.clients.add(client)
        self.sockets_per_ip[ip] = self.sockets_per_ip.get(ip, 0) + 1
        try:
            async for raw in ws:
                if client.closing:
                    break
                if not client.bucket.take():
                    log.warning("event=rate_limited reason=messages ip=%s room=%s sid=%d",
                                ip, client.room.code if client.room else "-", client.sid)
                    if client.room is not None:
                        # In a room (a host trickling candidates to several
                        # joiners): drop the excess, closing would kill the room.
                        continue
                    await self._error(client, E_RATE_LIMITED, "Too many messages.", True, CLOSE_POLICY)
                    break
                await self._on_message(client, raw)
        except ConnectionClosed:
            pass
        except Exception:  # never let one socket kill the server
            log.exception("event=handler_error ip=%s", ip)
        finally:
            self.clients.discard(client)
            n = self.sockets_per_ip.get(ip, 1) - 1
            if n > 0:
                self.sockets_per_ip[ip] = n
            else:
                self.sockets_per_ip.pop(ip, None)
            await self._leave(client)

    async def _on_message(self, client: Client, raw: Any) -> None:
        msg: Any = None
        if isinstance(raw, str):
            try:
                msg = json.loads(raw)
            except ValueError:
                msg = None
        if not isinstance(msg, dict) or not isinstance(msg.get("op"), str):
            await self._error(client, E_BAD_REQUEST, "Expected a JSON object with an \"op\".")
            return
        op = msg["op"]
        if op == "ping":
            await self._send(client, {"op": "pong"})
        elif op == "host":
            await self._on_host(client, msg)
        elif op == "join":
            await self._on_join(client, msg)
        elif op == "signal":
            await self._on_signal(client, msg)
        else:
            await self._error(client, E_BAD_REQUEST, f"Unknown op {op[:32]!r}.")

    async def _on_host(self, client: Client, msg: dict) -> None:
        cfg = self.cfg
        if client.room is not None:
            await self._error(client, E_ALREADY_IN_ROOM, "Already in a room.", True)
            return
        game, max_guests = msg.get("game"), msg.get("max_guests")
        if (not isinstance(game, str) or not game or not isinstance(max_guests, int) or isinstance(max_guests, bool)
                or not 1 <= max_guests <= cfg.max_guests_cap):
            await self._error(client, E_BAD_REQUEST,
                              f"host needs a game string and max_guests in 1..{cfg.max_guests_cap}.", True)
            return
        if len(self.rooms) >= cfg.max_rooms:
            log.warning("event=reject reason=max_rooms ip=%s", client.ip)
            await self._error(client, E_SERVER_FULL, "Server is full, try again later.", True)
            return
        if self.rooms_per_ip.get(client.ip, 0) >= cfg.max_rooms_per_ip:
            log.warning("event=rate_limited reason=rooms_per_ip ip=%s", client.ip)
            await self._error(client, E_RATE_LIMITED, "Too many rooms from your address.", True)
            return
        code = self._new_code()
        room = Room(code, game, max_guests, client)
        self.rooms[code] = room
        self.rooms_per_ip[client.ip] = self.rooms_per_ip.get(client.ip, 0) + 1
        client.room, client.sid = room, HOST_SID
        log.info("event=room_created room=%s ip=%s max_guests=%d rooms=%d",
                 code, client.ip, max_guests, len(self.rooms))
        await self._send(client, {"op": "hosted", "room": code, "peer": HOST_SID,
                                  "ice_servers": ice_servers(cfg, self.turn_secret, f"{code}-{HOST_SID}")})

    async def _on_join(self, client: Client, msg: dict) -> None:
        if client.room is not None:
            await self._error(client, E_ALREADY_IN_ROOM, "Already in a room.", True)
            return
        code, game = msg.get("room"), msg.get("game")
        if not isinstance(code, str) or not isinstance(game, str):
            await self._error(client, E_BAD_REQUEST, "join needs room and game strings.", True)
            return
        room = self.rooms.get(code.strip().upper())
        if room is None or room.host is None:
            await self._error(client, E_ROOM_NOT_FOUND, "No room with that code.", True)
            return
        if game != room.game:
            await self._error(client, E_VERSION_MISMATCH,
                              "The host runs a different version of the game.", True)
            return
        if len(room.guests) >= room.max_guests:
            await self._error(client, E_ROOM_FULL, "That room is full.", True)
            return
        sid = room.next_sid
        room.next_sid += 1
        room.guests[sid] = client
        client.room, client.sid = room, sid
        client.joined = time.monotonic()
        log.info("event=peer_joined room=%s sid=%d ip=%s", room.code, sid, client.ip)
        await self._send(client, {"op": "joined", "room": room.code, "peer": sid,
                                  "ice_servers": ice_servers(self.cfg, self.turn_secret, f"{room.code}-{sid}")})
        await self._send(room.host, {"op": "peer_joined", "peer": sid})

    async def _on_signal(self, client: Client, msg: dict) -> None:
        room, to, data = client.room, msg.get("to"), msg.get("data")
        if (room is None or not isinstance(to, int) or isinstance(to, bool)
                or not isinstance(data, dict)):
            await self._error(client, E_BAD_REQUEST, "signal needs a room, an int to and an object data.")
            return
        if client.sid == HOST_SID:
            target = room.guests.get(to)
            if target is None:
                if HOST_SID < to < room.next_sid:
                    return  # guest already left signaling: drop late candidates quietly
                await self._error(client, E_BAD_REQUEST, f"No guest {to} in this room.")
                return
        else:
            if to != HOST_SID:
                await self._error(client, E_BAD_REQUEST, "Guests may only signal the host (1).")
                return
            target = room.host
            if target is None:
                return
        await self._send(target, {"op": "signal", "from": client.sid, "data": data})

    # ---- rooms

    def _new_code(self) -> str:
        while True:
            code = "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(ROOM_CODE_LENGTH))
            if code not in self.rooms:
                return code

    async def _leave(self, client: Client) -> None:
        room = client.room
        if room is None:
            return
        client.room = None
        if client.sid == HOST_SID:
            await self._close_room(room, "host_left")
        elif room.guests.pop(client.sid, None) is not None:
            log.info("event=peer_left room=%s sid=%d", room.code, client.sid)
            if room.host is not None:
                await self._send(room.host, {"op": "peer_left", "peer": client.sid})

    async def _close_room(self, room: Room, reason: str) -> None:
        if self.rooms.get(room.code) is not room:
            return
        del self.rooms[room.code]
        host = room.host
        room.host = None
        if host is not None:
            n = self.rooms_per_ip.get(host.ip, 1) - 1
            if n > 0:
                self.rooms_per_ip[host.ip] = n
            else:
                self.rooms_per_ip.pop(host.ip, None)
        log.info("event=room_closed room=%s reason=%s age=%.0fs guests_on_signaling=%d rooms=%d",
                 room.code, reason, time.monotonic() - room.created, len(room.guests), len(self.rooms))
        guests = list(room.guests.values())
        room.guests.clear()
        for g in guests:
            g.room = None
            await self._send(g, {"op": "room_closed"})
            self._spawn(self._close(g, CLOSE_NORMAL, "room_closed"))

    # ---- sweeper (idle sockets, room lifetime)

    async def _sweep_loop(self) -> None:
        while True:
            await asyncio.sleep(self.cfg.sweep_interval)
            try:
                await self._sweep()
            except Exception:
                log.exception("event=sweep_error")

    async def _sweep(self) -> None:
        now = time.monotonic()
        for c in list(self.clients):
            if c.room is None and not c.closing and now - c.opened > self.cfg.idle_timeout:
                log.info("event=idle_close ip=%s", c.ip)
                self._spawn(self._close(c, CLOSE_IDLE, "idle"))
            elif (c.room is not None and c.sid != HOST_SID and not c.closing
                    and now - c.joined > self.cfg.guest_ttl):
                log.info("event=guest_ttl room=%s sid=%d ip=%s", c.room.code, c.sid, c.ip)
                self._spawn(self._close(c, CLOSE_GUEST_TTL, "guest_ttl"))
        for room in list(self.rooms.values()):
            if now - room.created > self.cfg.room_lifetime:
                host = room.host
                if host is not None:
                    host.room = None
                    await self._send(host, {"op": "room_closed"})
                    self._spawn(self._close(host, CLOSE_ROOM_EXPIRED, "room_lifetime"))
                await self._close_room(room, "lifetime")


# --------------------------------------------------------------------------

def main(argv: Optional[list] = None) -> int:
    cfg = config_from(argv)
    logging.basicConfig(level=cfg.log_level.upper(),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("websockets").setLevel(logging.ERROR)  # scanners, bad handshakes
    server = SignalingServer(cfg)
    try:
        asyncio.run(server.serve_forever())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
