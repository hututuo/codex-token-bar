#!/usr/bin/env python3
"""Reference server for the Agent Speed Live Report API (spec/REPORTING.md), standard library only.

For local testing by Agent Speed developers and by services that implement the API: it serves the discovery
document, registers devices, verifies every signature, enforces the timestamp window, nonce cache, sequence
rules, size and rate limits, and prints every report it accepts. State is in memory and lost on exit.

  python3 spec/tools/report_server.py                       http://127.0.0.1:8787
  python3 spec/tools/report_server.py --api-path /agent-speed --api-key-mode required --api-key secret-123
  python3 spec/tools/report_server.py --tls-cert cert.pem --tls-key key.pem --public-url https://test.local:8787

Then, in another terminal, the reference client:

  python3 spec/tools/report_reference.py client --url http://127.0.0.1:8787 --username demo --reports 3

GET / shows a plain-text table of the devices and their summed deltas. Not for production use.
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import report_reference as ref  # noqa: E402


def build_service(args) -> ref.ReferenceService:
    public = args.public_url or f"{'https' if args.tls_cert else 'http'}://{args.host}:{args.port}"
    rules = {"minLength": args.min_length, "maxLength": args.max_length, "charset": args.charset,
             "spaces": not args.no_spaces}
    limits = {**ref.DEFAULT_LIMITS, "intervalSeconds": args.interval}
    service = ref.ReferenceService(authority=ref.authority_of(public), api_path=args.api_path, name=args.name,
                                   api_key_mode=args.api_key_mode, api_keys=tuple(args.api_key), rules=rules,
                                   limits=limits, log=lambda line: print(line, flush=True),
                                   extensions={name: 1 for name in ref.EXTENSIONS} if args.extensions else None)
    service.public_scheme = public.split("://", 1)[0]
    return service


class Handler(BaseHTTPRequestHandler):
    server_version = "AgentSpeedReferenceServer/1"
    service: ref.ReferenceService
    lock = threading.Lock()
    verbose = False

    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write(f"{self.address_string()} {fmt % args}\n")

    def _send(self, status: int, headers: dict, payload, content_type: str = "application/json") -> None:
        data = b"" if payload is None else (payload if isinstance(payload, bytes)
                                            else json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def _dispatch(self) -> None:
        method = self.command
        if method == "GET" and self.path in ("/", "/status"):
            self._send(200, {}, self._status_page().encode("utf-8"), "text/plain; charset=utf-8")
            return
        if method == "GET" and self.path.split("?")[0] == "/.well-known/agent-speed-report":
            with self.lock:
                document = self.service.discovery(self.service.public_scheme)
            self._send(200, {"Cache-Control": "max-age=60"}, document)
            return
        body = b""
        if method in ("POST", "PATCH", "PUT", "DELETE"):
            if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                self._send(411, {}, {"error": {"code": "length_required"}})
                return
            length = self.headers.get("Content-Length")
            if length is None and method != "DELETE":
                self._send(411, {}, {"error": {"code": "length_required"}})
                return
            try:
                size = int(length or 0)
            except ValueError:
                self._send(400, {}, {"error": {"code": "bad_request", "field": "Content-Length"}})
                return
            avatar_upload = (method == "PUT" and self.path == self.service.api_path + "/v1/profile/avatar"
                             and ref.supported(self.service.extensions, "profileAvatar"))
            body_limit = 512 * 1024 if avatar_upload else self.service.limits["maxBodyBytes"]
            if size < 0 or size > body_limit:
                status = 400 if size < 0 else 413
                code = "bad_request" if size < 0 else ("avatar_too_large" if avatar_upload else "payload_too_large")
                self._send(status, {"Connection": "close"}, {"error": {"code": code}})
                self.close_connection = True
                return
            body = self.rfile.read(size)
        headers = {name: value for name, value in self.headers.items()}
        with self.lock:
            status, extra, payload = self.service.handle(method, self.path, headers, body,
                                                         client_ip=self.client_address[0])
            if self.verbose and self.path.endswith("/v1/reports") and status == 200:
                print(json.dumps(json.loads(body), ensure_ascii=False, indent=2), flush=True)
        if status >= 400 and self.verbose:
            print(f"  -> {status} {payload['error']['code']}", flush=True)
        content_type = next((v for k, v in extra.items() if k.lower() == "content-type"), "application/json")
        self._send(status, {k: v for k, v in extra.items() if k.lower() != "content-type"}, payload, content_type)

    def _status_page(self) -> str:
        with self.lock:
            devices = list(self.service.devices.items())
            online = {id(d) for d in self.service.online()}
        lines = [f"{self.service.name} - {len(devices)} device(s)", "",
                 f"{'username':<24} {'online':<7} {'activity':<8} {'tok/s':>9} {'output':>12} {'requests':>9} "
                 f"{'cost US$':>12}"]
        for device_id, device in sorted(devices, key=lambda item: item[1]["username"]):
            last = device.get("last") or {}
            totals = device["totals"]
            lines.append(f"{device['username']:<24} {'yes' if id(device) in online else 'no':<7} "
                         f"{last.get('activity', '-'):<8} {last.get('live', {}).get('outputTokS', 0):>9.1f} "
                         f"{totals.get('output', 0):>12} {totals.get('requests', 0):>9} "
                         f"{totals.get('costMicroUsd', 0) / 1e6:>12.6f}")
        return "\n".join(lines) + "\n"

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _dispatch


def main() -> int:
    # Usernames are Unicode; Windows consoles and pipes otherwise use a legacy code page and fail mid-request.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    parser = argparse.ArgumentParser(description="Agent Speed Live Report API reference server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--public-url", help="the service URL clients use (default http(s)://host:port); its "
                                             "host and port are the signed authority")
    parser.add_argument("--api-path", default="", help="path prefix of the API, e.g. /agent-speed")
    parser.add_argument("--name", default="Agent Speed reference server")
    parser.add_argument("--api-key-mode", choices=("none", "optional", "required"), default="none")
    parser.add_argument("--api-key", action="append", default=[], help="an accepted API key (repeatable)")
    parser.add_argument("--charset", choices=("unicode", "ascii"), default="unicode")
    parser.add_argument("--min-length", type=int, default=2)
    parser.add_argument("--max-length", type=int, default=32)
    parser.add_argument("--no-spaces", action="store_true")
    parser.add_argument("--interval", type=int, default=5, help="intervalSeconds in the discovery document")
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    parser.add_argument("--verbose", action="store_true", help="print every accepted report in full")
    parser.add_argument("--extensions", action="store_true", help="enable the optional mode/profile/pairing reference APIs")
    args = parser.parse_args()
    Handler.service = build_service(args)
    Handler.verbose = args.verbose
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    scheme = "http"
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.tls_cert, args.tls_key)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    if args.host not in ("127.0.0.1", "::1", "localhost"):
        print("warning: listening beyond loopback; this server keeps no data safe and is for testing only")
    service = Handler.service
    print(f"listening on {scheme}://{args.host}:{args.port}  signed authority {service.authority!r}  "
          f"api path {service.api_path or '/'}  api key {service.api_key_mode}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
