#!/usr/bin/env python3
"""Prometheus exporter for Dream Router firewall / port-forward hit counters.

UniFi's API does not expose nf_conntrack / NAT table size. The closest
signal for WAN scans and lobby-port bots is firewall_hits_state, especially
WAN_PF_IN (port-forward hits) and WAN_LOCAL (hits aimed at the router).
"""

from __future__ import annotations

import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

INTERESTING_CHAINS = frozenset(
    {"WAN_IN", "WAN_LOCAL", "WAN_OUT", "WAN_PF_IN", "WAN_PF_OUT"}
)


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def load_password() -> str:
    path = Path(_env("UNIFI_PASS_FILE", "/var/lib/monitoring/secrets/unpoller.pass"))
    return path.read_text(encoding="utf-8").strip()


def prom_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render_metrics(hits: list[dict]) -> str:
    lines = [
        "# HELP udr_firewall_packets_total Packets counted by UniFi firewall_hits_state",
        "# TYPE udr_firewall_packets_total counter",
    ]
    for entry in hits:
        chain = str(entry.get("chain") or "")
        if chain not in INTERESTING_CHAINS:
            continue
        rid = str(entry.get("id") or "")
        packets = int(entry.get("packets") or 0)
        lines.append(
            f'udr_firewall_packets_total{{chain="{prom_escape(chain)}",'
            f'rule="{prom_escape(rid)}"}} {packets}'
        )
    lines.append("# HELP udr_fw_exporter_up 1 if the last UniFi poll succeeded")
    lines.append("# TYPE udr_fw_exporter_up gauge")
    return "\n".join(lines) + "\n"


class UnifiClient:
    def __init__(self) -> None:
        self.host = _env("UNIFI_HOST", "https://192.168.1.1").rstrip("/")
        if not self.host.startswith("http"):
            self.host = f"https://{self.host}"
        self.user = _env("UNIFI_USER", "unpoller")
        self.password = load_password()
        self._opener: urllib.request.OpenerDirector | None = None
        self._csrf: str | None = None

    def _ssl_context(self) -> ssl.SSLContext:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx

    def login(self) -> None:
        jar = CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=self._ssl_context()),
            urllib.request.HTTPCookieProcessor(jar),
        )
        body = json.dumps({"username": self.user, "password": self.password}).encode()
        req = urllib.request.Request(
            f"{self.host}/api/auth/login",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self._opener.open(req, timeout=20) as resp:
            self._csrf = resp.headers.get("X-CSRF-Token") or resp.headers.get("x-csrf-token")
            resp.read()
        if not self._csrf:
            for cookie in jar:
                if cookie.name.upper() in ("CSRF_TOKEN", "X-CSRF-TOKEN"):
                    self._csrf = cookie.value
                    break

    def get(self, path: str) -> Any:
        if self._opener is None:
            self.login()
        assert self._opener is not None
        headers = {"Accept": "application/json"}
        if self._csrf:
            headers["X-CSRF-Token"] = self._csrf
        req = urllib.request.Request(self.host + path, headers=headers)
        try:
            with self._opener.open(req, timeout=25) as resp:
                parsed = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                self.login()
                return self.get(path)
            raise
        if isinstance(parsed, dict) and "data" in parsed:
            return parsed["data"]
        return parsed

    def poll(self) -> list[dict]:
        devices = self.get("/proxy/network/api/s/default/stat/device")
        for item in devices if isinstance(devices, list) else []:
            if item.get("type") != "udm":
                continue
            return list((item.get("firewall_hits_state") or {}).get("entries") or [])
        return []


class Poller:
    """Polls the controller on its own timer and keeps the last rendering.

    Scrapes read from memory, so a slow or dead controller can never turn into
    a scrape timeout: Prometheus sees the exporter as up, and the exporter says
    what it knows via udr_fw_exporter_up (did the LAST poll succeed) and
    udr_fw_poll_seconds (how long the router took to answer). That split is
    the whole point -- on 10-11 Sep 2026 the old per-scrape design timed out
    on every scrape for 12h, so `up` was 0 and nothing recorded that the
    router was answering, slowly, right up until it wasn't.
    """

    def __init__(self, client: UnifiClient, interval: float) -> None:
        self.client = client
        self.interval = interval
        self._lock = threading.Lock()
        self._hits: list[dict] = []
        self._ok = False
        self._last_success = 0.0
        self._poll_seconds = 0.0
        self._last_error = ""

    def poll_once(self, now: float | None = None) -> None:
        started = time.monotonic()
        try:
            hits = self.client.poll()
        except Exception as exc:
            with self._lock:
                self._ok = False
                self._poll_seconds = time.monotonic() - started
                self._last_error = type(exc).__name__
            return
        with self._lock:
            self._hits = hits
            self._ok = True
            self._poll_seconds = time.monotonic() - started
            self._last_success = time.time() if now is None else now
            self._last_error = ""

    def run_forever(self) -> None:
        while True:
            self.poll_once()
            time.sleep(self.interval)

    def render(self) -> str:
        with self._lock:
            hits = list(self._hits)
            ok, last, secs, err = self._ok, self._last_success, self._poll_seconds, self._last_error
        body = render_metrics(hits)
        body += f"udr_fw_exporter_up {1 if ok else 0}\n"
        body += "# HELP udr_fw_poll_seconds Wall time of the last controller poll, success or not\n"
        body += "# TYPE udr_fw_poll_seconds gauge\n"
        body += f"udr_fw_poll_seconds {secs:.3f}\n"
        body += "# HELP udr_fw_last_success_timestamp_seconds Unix time of the last successful poll\n"
        body += "# TYPE udr_fw_last_success_timestamp_seconds gauge\n"
        body += f"udr_fw_last_success_timestamp_seconds {last:.0f}\n"
        if err:
            body += f"# poll_error {err}\n"
        return body


class Handler(BaseHTTPRequestHandler):
    poller: Poller

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] not in ("/metrics", "/"):
            self.send_error(404)
            return
        raw = Handler.poller.render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except BrokenPipeError:
            # The scraper gave up before we wrote. With a cache read that is
            # rare; without this it was a 15-line traceback per occurrence.
            return


def main() -> None:
    bind = _env("UDR_FW_BIND", "127.0.0.1:9131")
    host, port_s = bind.rsplit(":", 1)
    interval = float(_env("UDR_FW_POLL_SECONDS", "300"))
    Handler.poller = Poller(UnifiClient(), interval)
    threading.Thread(target=Handler.poller.run_forever, daemon=True, name="udr-poll").start()
    server = ThreadingHTTPServer((host, int(port_s)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
