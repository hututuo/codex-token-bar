#!/usr/bin/env python3
"""Reference implementation of the Agent Speed Live Report API (spec/REPORTING.md, METRICS 11).

Standard library only. It implements:

- ECDSA P-256 / SHA-256 with IEEE P1363 signatures (r || s, 64 bytes), deterministic per RFC 6979;
- JWK and SPKI public keys and RFC 7638 thumbprints;
- the canonical request string, request signing and verification (REPORTING 5);
- usernames: validation, fitting a computer name, comparison keys (REPORTING 4.3);
- report validation with spec/report-schema.json plus the rules a schema cannot express (REPORTING 6);
- every server rule of REPORTING 4, 7 and 8 as an in-memory service (used by report_server.py);
- the client report scheduler of METRICS 11.5 as a simulator;
- what a client accepts from a discovery document (REPORTING 2.2, 3.2);
- spec/fixtures/report-vectors.json: checked by default, regenerated with --write.

The ECDSA code is for tests and local servers only: it is not constant time. Apps use CryptoKit or
System.Security.Cryptography; production servers use a vetted library.

Usage:
  python3 spec/tools/report_reference.py [--verbose]       check vectors, examples and schema
  python3 spec/tools/report_reference.py --write            regenerate spec/fixtures/report-vectors.json
  python3 spec/tools/report_reference.py client --url URL   act as an Agent Speed client (see --help)
"""

from __future__ import annotations

import argparse
import base64
import calendar
import copy
import hashlib
import hmac
import json
import re
import secrets
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from execution_modes_reference import EXTENSIONS, report_extension_errors, supported

SPEC = Path(__file__).resolve().parent.parent
SCHEMA_PATH = SPEC / "report-schema.json"
VECTORS_PATH = SPEC / "fixtures" / "report-vectors.json"
EXAMPLES_DIR = SPEC / "fixtures" / "report-examples"

SOURCES = ("codex", "claudeCode", "claudeDesktop", "deepseek", "opencode", "gemini", "omp", "antigravity", "workbuddy",
           "workbuddyAi", "zcode", "kimi", "grokBuild")


def source_order(source):
    return (SOURCES.index(source), "") if source in SOURCES else (len(SOURCES), source)


SECTIONS = ("sources", "models", "cost", "traffic")
DEFAULT_SECTIONS = SECTIONS  # DESIGN 11: every section switch is on by default
LABEL = "AGENTSPEED-V1"
SKEW_SECONDS = 300
NONCE_TTL_SECONDS = 600
SEQ_TTL_SECONDS = 900
MAX_MARKS_IN_A_ROW = 4
PROTOCOL_MAX_BODY = 65_536
DEFAULT_LIMITS = {"intervalSeconds": 5, "heartbeatSeconds": 60, "maxAgeSeconds": 30, "maxBodyBytes": 16_384,
                  "maxModels": 16}
DEFAULT_USERNAME_RULES = {"minLength": 2, "maxLength": 32, "charset": "unicode", "spaces": True}

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
TIMESTAMP_RE = re.compile(r"^[1-9][0-9]{9}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
SIGNATURE_RE = re.compile(r"^[A-Za-z0-9_-]{86}$")
PATH_RE = re.compile(r"^/[A-Za-z0-9\-._~%!$&'()*+,;=:@/]*(\?[A-Za-z0-9\-._~%!$&'()*+,;=:@/?]*)?$")
SENT_AT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")


# ------------------------------------------------------------------------------------------------- encoding

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text: str) -> bytes:
    """Strict unpadded base64url: other alphabets, padding and non-zero trailing bits are rejected."""
    if not isinstance(text, str) or not re.fullmatch(r"[A-Za-z0-9_-]*", text) or len(text) % 4 == 1:
        raise ValueError("not unpadded base64url")
    data = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    if b64url(data) != text:
        raise ValueError("non-canonical base64url")
    return data


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compact_json(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def format_instant(ms: int) -> str:
    seconds, millis = divmod(ms, 1000)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(seconds)) + f".{millis:03d}Z"


def parse_instant(text: str) -> int:
    if not SENT_AT_RE.match(text):
        raise ValueError("bad instant")
    whole = calendar.timegm(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S"))
    return whole * 1000 + int(text[20:23])


# ------------------------------------------------------------------------------------------------- P-256

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def _double(p):
    if p is None or p[1] == 0:
        return None
    x, y, z = p
    delta = z * z % P
    gamma = y * y % P
    beta = x * gamma % P
    alpha = 3 * (x - delta) * (x + delta) % P
    x3 = (alpha * alpha - 8 * beta) % P
    z3 = ((y + z) * (y + z) - gamma - delta) % P
    y3 = (alpha * (4 * beta - x3) - 8 * gamma * gamma) % P
    return x3, y3, z3


def _add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    x1, y1, z1 = p
    x2, y2, z2 = q
    z1z1 = z1 * z1 % P
    z2z2 = z2 * z2 % P
    u1 = x1 * z2z2 % P
    u2 = x2 * z1z1 % P
    s1 = y1 * z2 * z2z2 % P
    s2 = y2 * z1 * z1z1 % P
    if u1 == u2:
        return _double(p) if s1 == s2 else None
    h = (u2 - u1) % P
    r = (s2 - s1) % P
    hh = h * h % P
    hhh = h * hh % P
    v = u1 * hh % P
    x3 = (r * r - hhh - 2 * v) % P
    y3 = (r * (v - x3) - s1 * hhh) % P
    return x3, y3, z1 * z2 * h % P


def _multiply(k: int, point):
    result = None
    addend = (point[0], point[1], 1)
    for bit in bin(k)[2:]:
        result = _double(result)
        if bit == "1":
            result = _add(result, addend)
    return result


def _affine(p):
    if p is None:
        return None
    x, y, z = p
    zi = pow(z, -1, P)
    zi2 = zi * zi % P
    return x * zi2 % P, y * zi2 * zi % P


def on_curve(x: int, y: int) -> bool:
    return 0 <= x < P and 0 <= y < P and (y * y - (x * x * x - 3 * x + B)) % P == 0


def public_key(d: int) -> tuple[int, int]:
    if not 1 <= d < N:
        raise ValueError("private key out of range")
    return _affine(_multiply(d, G))


def _rfc6979(d: int, digest: bytes):
    x = d.to_bytes(32, "big")
    h = (int.from_bytes(digest, "big") % N).to_bytes(32, "big")
    v, k = b"\x01" * 32, b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        candidate = int.from_bytes(v, "big")
        if 1 <= candidate < N:
            yield candidate
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def sign(d: int, message: bytes) -> bytes:
    """ES256 over the message bytes (SHA-256 inside), deterministic k (RFC 6979), r || s, s not normalized."""
    digest = hashlib.sha256(message).digest()
    e = int.from_bytes(digest, "big")
    for k in _rfc6979(d, digest):
        r = _affine(_multiply(k, G))[0] % N
        if r == 0:
            continue
        s = pow(k, -1, N) * (e + r * d) % N
        if s == 0:
            continue
        return r.to_bytes(32, "big") + s.to_bytes(32, "big")
    raise AssertionError("unreachable")


def verify(pub: tuple[int, int], message: bytes, signature: bytes) -> bool:
    if len(signature) != 64 or not on_curve(*pub):
        return False
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    if not (1 <= r < N and 1 <= s < N):
        return False
    e = int.from_bytes(hashlib.sha256(message).digest(), "big")
    w = pow(s, -1, N)
    point = _affine(_add(_multiply(e * w % N, G), _multiply(r * w % N, pub)))
    return point is not None and point[0] % N == r


def der_signature(signature: bytes) -> bytes:
    """ASN.1 DER form of a raw signature (what OpenSSL and some libraries use; never sent by the protocol)."""
    def integer(value: bytes) -> bytes:
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value
    body = integer(signature[:32]) + integer(signature[32:])
    return b"\x30" + bytes([len(body)]) + body


# ------------------------------------------------------------------------------------------------- keys

SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")


def jwk(pub: tuple[int, int]) -> dict:
    return {"kty": "EC", "crv": "P-256", "x": b64url(pub[0].to_bytes(32, "big")),
            "y": b64url(pub[1].to_bytes(32, "big"))}


def parse_jwk(value) -> tuple[int, int]:
    """A validated public key: kty EC, crv P-256, canonical 43-character coordinates below p, on the curve, no d."""
    if not isinstance(value, dict) or value.get("kty") != "EC" or value.get("crv") != "P-256":
        raise ValueError("not a P-256 JWK")
    if "d" in value:
        raise ValueError("a public key must not contain d")
    try:
        x, y = b64url_decode(value.get("x")), b64url_decode(value.get("y"))
    except (ValueError, TypeError) as error:
        raise ValueError("bad coordinate encoding") from error
    if len(x) != 32 or len(y) != 32:
        raise ValueError("coordinates must be 32 bytes")
    point = int.from_bytes(x, "big"), int.from_bytes(y, "big")
    if not on_curve(*point):
        raise ValueError("point is not on P-256")
    return point


def spki(pub: tuple[int, int]) -> bytes:
    return SPKI_PREFIX + b"\x04" + pub[0].to_bytes(32, "big") + pub[1].to_bytes(32, "big")


def thumbprint(pub: tuple[int, int]) -> str:
    key = jwk(pub)
    members = '{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}' % (key["x"], key["y"])
    return b64url(hashlib.sha256(members.encode("ascii")).digest())


def test_private_key(label: str) -> int:
    return int.from_bytes(hashlib.sha256(label.encode("utf-8")).digest(), "big") % (N - 1) + 1


# ------------------------------------------------------------------------------------------------- signing

def authority_of(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    if ":" in host:
        host = f"[{host}]"
    default = {"https": 443, "http": 80}.get(parts.scheme)
    return host if parts.port in (None, default) else f"{host}:{parts.port}"


def path_of(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return (parts.path or "/") + (f"?{parts.query}" if parts.query else "")


def canonical_string(method: str, authority: str, path: str, timestamp: str, nonce: str, device_id: str,
                     body: bytes) -> str:
    return "\n".join([LABEL, method, authority, path, timestamp, nonce, device_id, sha256_hex(body)])


def new_nonce() -> str:
    return b64url(secrets.token_bytes(16))


def signed_headers(d: int, method: str, url: str, device_id: str, body: bytes, *, timestamp: int | None = None,
                   nonce: str | None = None, api_key: str | None = None, version: str = "0.0.0",
                   platform: str = "macOS", new_key: int | None = None) -> dict:
    timestamp_text = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or new_nonce()
    canonical = canonical_string(method, authority_of(url), path_of(url), timestamp_text, nonce, device_id, body)
    headers = {"User-Agent": f"AgentSpeed/{version} ({platform})", "Accept": "application/json"}
    if body:
        headers["Content-Type"] = "application/json"
    headers.update({"X-AgentSpeed-Device": device_id, "X-AgentSpeed-Timestamp": timestamp_text,
                    "X-AgentSpeed-Nonce": nonce,
                    "X-AgentSpeed-Signature": b64url(sign(d, canonical.encode("utf-8")))})
    if new_key is not None:
        headers["X-AgentSpeed-New-Key-Signature"] = b64url(sign(new_key, canonical.encode("utf-8")))
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return headers


def check_signature_headers(headers: dict) -> str | None:
    """Field name of the first malformed signature header, or None. Header names are lowercase."""
    if not UUID_RE.match(headers.get("x-agentspeed-device", "")):
        return "X-AgentSpeed-Device"
    if not TIMESTAMP_RE.match(headers.get("x-agentspeed-timestamp", "")):
        return "X-AgentSpeed-Timestamp"
    if not NONCE_RE.match(headers.get("x-agentspeed-nonce", "")):
        return "X-AgentSpeed-Nonce"
    if not SIGNATURE_RE.match(headers.get("x-agentspeed-signature", "")):
        return "X-AgentSpeed-Signature"
    for name, size in (("x-agentspeed-nonce", 16), ("x-agentspeed-signature", 64)):
        try:
            if len(b64url_decode(headers[name])) != size:
                raise ValueError
        except ValueError:
            return "X-AgentSpeed-Nonce" if size == 16 else "X-AgentSpeed-Signature"
    return None


def verify_signature(pub, method: str, authority: str, path: str, headers: dict, body: bytes,
                     header: str = "x-agentspeed-signature") -> bool:
    try:
        signature = b64url_decode(headers.get(header, ""))
    except ValueError:
        return False
    canonical = canonical_string(method, authority, path, headers["x-agentspeed-timestamp"],
                                 headers["x-agentspeed-nonce"], headers["x-agentspeed-device"], body)
    return verify(pub, canonical.encode("utf-8"), signature)


# ------------------------------------------------------------------------------------------------- usernames

APOSTROPHES = "'‘’ʼ`"
SAFE_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz"


def username_rules(discovery_rules: dict | None) -> dict:
    rules = dict(DEFAULT_USERNAME_RULES)
    rules.update({k: v for k, v in (discovery_rules or {}).items() if k in rules})
    rules["minLength"] = min(max(1, int(rules["minLength"])), 12)
    rules["maxLength"] = min(max(12, int(rules["maxLength"])), 32)
    return rules


def _letter_or_number(ch: str, rules: dict) -> bool:
    if rules["charset"] == "ascii":
        return ch.isascii() and ch.isalnum()
    return unicodedata.category(ch)[0] in "LN"


def _allowed(ch: str, rules: dict) -> bool:
    if ch == " ":
        return bool(rules["spaces"])
    if ch in "_-.":
        return True
    if rules["charset"] == "ascii":
        return ch.isascii() and ch.isalnum()
    return unicodedata.category(ch)[0] in "LMN"


def validate_username(name, rules: dict) -> str | None:
    """None when valid, else the first failing reason in REPORTING 4.3 order: characters, length, spaces, start."""
    if not isinstance(name, str) or unicodedata.normalize("NFKC", name) != name:
        return "characters"
    if not rules["minLength"] <= len(name) <= rules["maxLength"]:
        return "length"
    marks = 0
    for ch in name:
        if ch.isspace() and ch != " ":
            return "spaces"
        if not _allowed(ch, rules):
            return "spaces" if ch == " " else "characters"
        marks = marks + 1 if unicodedata.category(ch)[0] == "M" else 0
        if marks > MAX_MARKS_IN_A_ROW:
            return "characters"
    if not _letter_or_number(name[0], rules):
        return "start"
    if name.endswith(" ") or "  " in name:
        return "spaces"
    return None


def fit_username(computer_name: str, rules: dict) -> str | None:
    """The default username derived from the computer name, or None when nothing usable remains."""
    text = unicodedata.normalize("NFKC", computer_name)
    text = "".join(ch for ch in text if ch not in APOSTROPHES)
    if rules["charset"] == "ascii":
        text = "".join(ch for ch in unicodedata.normalize("NFKD", text) if not unicodedata.category(ch).startswith("M"))
    separator = " " if rules["spaces"] else "-"
    text = "".join(ch if (not ch.isspace() and _allowed(ch, rules)) else separator for ch in text)
    text = re.sub(r"[ \-]*-[ \-]*", "-", text)
    text = re.sub(r" {2,}", " ", text)
    while text and not _letter_or_number(text[0], rules):
        text = text[1:]
    text = text[: rules["maxLength"]].rstrip(" -_.")
    return text if validate_username(text, rules) is None else None


def random_username() -> str:
    return "racer-" + "".join(secrets.choice(SAFE_ALPHABET) for _ in range(6))


def username_key(name: str) -> str:
    return unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", name).casefold())


# ------------------------------------------------------------------------------------------------- schema

def load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _type_ok(value, name: str) -> bool:
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, {"string": str, "object": dict, "array": list}.get(name, type(None)))


def _same(a, b) -> bool:
    return a == b and isinstance(a, bool) == isinstance(b, bool)


def schema_errors(value, schema: dict, root: dict, path: str = "$", closed: bool = False) -> list[str]:
    """A JSON Schema subset (the keywords report-schema.json uses). closed=True rejects unknown properties."""
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target[part]
        return schema_errors(value, target, root, path, closed)
    errors: list[str] = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(value, name) for name in names):
            return [f"{path}: expected {'/'.join(names)}"]
    if "const" in schema and not _same(value, schema["const"]):
        errors.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: above {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: must be above {schema['exclusiveMinimum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: does not match {schema['pattern']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: more than {schema['maxItems']} items")
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            errors.append(f"{path}: items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                errors += schema_errors(item, schema["items"], root, f"{path}[{index}]", closed)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing {key}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                errors += schema_errors(item, properties[key], root, f"{path}.{key}", closed)
            elif closed and properties:
                errors.append(f"{path}: unknown property {key}")
    return errors


def _decimals_ok(value: float, places: int) -> bool:
    scaled = value * 10 ** places
    return abs(scaled - round(scaled)) < 1e-6


def heat(value: float, redline: float) -> float:
    return min(1.0, (value / redline) ** 0.6) if value > 0 else 0.0


def source_has_activity(entry: dict) -> bool:
    """REPORTING 6.6.3: some number of the entry as sent, other than agents.active and the shares, is non-zero."""
    values = [entry["live"]["outputTokS"], entry["live"]["totalTokS"], entry["agents"]["generating"],
              entry["agents"]["tools"], *entry["delta"].values()]
    if "cost" in entry:
        values += [entry["cost"][field] for field in ("liveMicroUsdPerSecond", "deltaMicroUsd", "unpricedRequests")]
    if "traffic" in entry:
        values += [value or 0 for value in entry["traffic"].values()]
    return any(value > 0 for value in values)


def report_errors(report, schema: dict, *, strict: bool = True, sections: tuple = SECTIONS,
                  max_models: int = 16) -> list[str]:
    """Schema errors plus the rules of REPORTING 6 that a schema cannot express (strict = conformance mode)."""
    errors = schema_errors(report, schema["$defs"]["report"], schema, closed=strict)
    if errors or not strict:
        return errors
    errors += [path + ": " + reason for path, reason in report_extension_errors(report)]
    live, peak, delta = report["live"], report["peak"], report["delta"]
    rates = [("live.outputTokS", live["outputTokS"]), ("live.totalTokS", live["totalTokS"]),
             ("peak.outputTokS", peak["outputTokS"]), ("peak.totalTokS", peak["totalTokS"])]
    shares = [("live.estimatedShare", live["estimatedShare"]), ("title.heat", report["title"]["heat"])]
    for entry in report.get("sources", []):
        rates += [(f"sources.{entry['source']}.live.outputTokS", entry["live"]["outputTokS"]),
                  (f"sources.{entry['source']}.live.totalTokS", entry["live"]["totalTokS"])]
        shares.append((f"sources.{entry['source']}.live.estimatedShare", entry["live"]["estimatedShare"]))
    if "cost" in report:
        shares.append(("cost.knownShare", report["cost"]["knownShare"]))
    errors += [f"{name}: more than one decimal" for name, value in rates if not _decimals_ok(value, 1)]
    errors += [f"{name}: more than three decimals" for name, value in shares if not _decimals_ok(value, 3)]
    if peak["outputTokS"] < live["outputTokS"] or peak["totalTokS"] < live["totalTokS"]:
        errors.append("peak: below the live value")
    if delta["measuredOutput"] > delta["output"]:
        errors.append("delta.measuredOutput: above delta.output")
    if delta["cachedInput"] + delta["cacheWriteInput"] > delta["input"]:
        errors.append("delta: cached and cache-write input exceed input")
    title = report["title"]
    value = live["outputTokS"] if title["metric"] == "output" else live["totalTokS"]
    if abs(round(heat(value, title["redline"]), 3) - title["heat"]) > 0.002:
        errors.append("title.heat: does not match the live value and redline")
    unknown = [key for key in SECTIONS if key in report and key not in sections]
    errors += [f"{key}: section not accepted by the service" for key in unknown]
    if "cost" in report:
        cost = report["cost"]
        if cost["peakMicroUsdPerSecond"] < cost["liveMicroUsdPerSecond"]:
            errors.append("cost.peakMicroUsdPerSecond: below the live value")
    for key in ("traffic",):
        block = report.get(key)
        if block is None:
            continue
        fields = ["rxBytesPerSecond", "txBytesPerSecond", "peakRxBytesPerSecond", "peakTxBytesPerSecond",
                  "rxBytes", "txBytes", "includesTools"]
        present = [field for field in fields if field in block]
        if block["status"] == "ok" and len(present) != len(fields):
            errors.append(f"{key}: status ok needs {', '.join(sorted(set(fields) - set(present)))}")
        if block["status"] != "ok" and present:
            errors.append(f"{key}: values present with status {block['status']}")
        for direction in ("rx", "tx"):
            rate, top = block.get(f"{direction}BytesPerSecond"), block.get(f"peak{direction.title()}BytesPerSecond")
            if rate is not None and top is not None and top < rate:
                errors.append(f"{key}: peak {direction} below the rate")
    if "sources" in report:
        listed = [entry["source"] for entry in report["sources"]]
        if listed != sorted(listed, key=source_order) or len(set(listed)) != len(listed):
            errors.append("sources: not unique or not in source order")
        for field in delta:
            if sum(entry["delta"][field] for entry in report["sources"]) != delta[field]:
                errors.append(f"sources: delta.{field} does not add up")
        for field in ("generating", "tools"):
            if sum(entry["agents"][field] for entry in report["sources"]) != live["agents"][field]:
                errors.append(f"sources: agents.{field} does not add up")
        for field in ("outputTokS", "totalTokS"):
            total = sum(entry["live"][field] for entry in report["sources"])
            if abs(total - live[field]) > 0.05 * len(listed) + 1e-6:
                errors.append(f"sources: live.{field} does not add up")
        for entry in report["sources"]:
            if ("cost" in entry) != ("cost" in report):
                errors.append(f"sources.{entry['source']}: cost present without the cost section or missing")
            traffic_ok = report.get("traffic", {}).get("status") == "ok"
            if ("traffic" in entry) != traffic_ok:
                errors.append(f"sources.{entry['source']}: traffic must be present exactly when traffic is ok")
            if not source_has_activity(entry):
                errors.append(f"sources.{entry['source']}: listed without activity")
        if "cost" in report:
            for field in ("deltaMicroUsd", "unpricedRequests"):
                if sum(entry["cost"][field] for entry in report["sources"]) != report["cost"][field]:
                    errors.append(f"sources: cost.{field} does not add up")
        if report.get("traffic", {}).get("status") == "ok":
            for field in ("rxBytes", "txBytes"):
                if sum(entry["traffic"][field] for entry in report["sources"]) != report["traffic"][field]:
                    errors.append(f"sources: traffic.{field} does not add up")
    if "models" in report:
        models = report["models"]
        if len(models) > max_models:
            errors.append("models: more entries than the service accepts")
        expected = sorted((m for m in models if m["id"] != "other"), key=lambda m: (-m["output"], m["id"]))
        expected += [m for m in models if m["id"] == "other"]
        if [m["id"] for m in models] != [m["id"] for m in expected]:
            errors.append("models: not ordered by output, then id, with other last")
        if len({m["id"] for m in models}) != len(models):
            errors.append("models: duplicate ids")
        for field in ("requests", "output", "measuredOutput", "measuredMs"):
            if sum(m[field] for m in models) != delta[field]:
                errors.append(f"models: {field} does not add up")
        if "cost" in report and sum(m.get("deltaMicroUsd", 0) for m in models) != report["cost"]["deltaMicroUsd"]:
            errors.append("models: deltaMicroUsd does not add up")
        if sum(m["generating"] for m in models) != live["agents"]["generating"]:
            errors.append("models: generating does not add up")
        for m in models:
            if m["sources"] != sorted(m["sources"], key=source_order):
                errors.append(f"models.{m['id']}: sources not in source order")
            if ("deltaMicroUsd" in m) != ("cost" in report):
                errors.append(f"models.{m['id']}: deltaMicroUsd must be present exactly with the cost section")
    if report["activity"] == "idle" and (live["agents"]["generating"] or live["agents"]["tools"]):
        errors.append("activity: idle while agents are working")
    return errors


# ------------------------------------------------------------------------------------------------- discovery

LIMIT_RANGES = {"intervalSeconds": (5, 300), "heartbeatSeconds": (30, 900), "maxAgeSeconds": (10, 120),
                "maxBodyBytes": (4096, 65_536), "maxModels": (0, 16)}
LOOPBACK_HTTP_RE = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/|$)")


class DiscoveryError(ValueError):
    """The discovery document is invalid; the argument names the first offending field."""


def _member(container: dict, key: str, kind: str, field: str, required: bool = False):
    if key not in container:
        if required:
            raise DiscoveryError(field)
        return None
    if not _type_ok(container[key], kind):
        raise DiscoveryError(field)
    return container[key]


def _plain_text(text: str, limit: int) -> str:
    """REPORTING 2.3: control and format characters removed, white space collapsed, length capped."""
    text = "".join(ch for ch in text if unicodedata.category(ch) not in ("Cc", "Cf") or ch.isspace())
    return " ".join(text.split())[:limit].rstrip()


def parse_discovery(document, fetched_from: str) -> dict:
    """What a client takes from a discovery document (REPORTING 2.2, 3.2): numbers clamped, optional links that are
    not https dropped, unknown fields ignored. Raises DiscoveryError(field) when the document is invalid."""
    schema = load_schema()

    def url_ok(definition: str, value: str) -> bool:
        return not schema_errors(value, schema["$defs"][definition], schema)

    if not isinstance(document, dict):
        raise DiscoveryError("$")
    if _member(document, "protocol", "string", "protocol", True) != "agent-speed-report":
        raise DiscoveryError("protocol")
    versions = _member(document, "versions", "array", "versions", True)
    if not versions or not all(_type_ok(version, "integer") for version in versions):
        raise DiscoveryError("versions")
    service = _member(document, "service", "object", "service", True)
    name = _plain_text(_member(service, "name", "string", "service.name", True), 40)
    if not name:
        raise DiscoveryError("service.name")
    result = {"versions": list(versions), "name": name}
    for key, limit in (("description", 200), ("contact", 254)):
        text = _member(service, key, "string", f"service.{key}")
        result[key] = (_plain_text(text, limit) or None) if text is not None else None
    for key in ("terms", "privacy"):
        link = _member(service, key, "string", f"service.{key}", True)
        if not url_ok("httpsUrl", link):
            raise DiscoveryError(f"service.{key}")
        result[key] = link
    for key in ("homepage", "leaderboard"):
        link = _member(service, key, "string", f"service.{key}")
        result[key] = link if link is not None and url_ok("httpsUrl", link) else None
    retention = _member(service, "retentionDays", "integer", "service.retentionDays")
    result["retentionDays"] = None if retention is None else min(max(retention, 0), 3650)

    api = _member(document, "api", "string", "api", True)
    if not url_ok("apiUrl", api) or (api.startswith("http://") and not LOOPBACK_HTTP_RE.match(fetched_from)):
        raise DiscoveryError("api")
    scheme, rest = api.split("://", 1)
    authority, slash, path = rest.partition("/")
    result["api"] = f"{scheme}://{authority.lower()}{slash}{path}".removesuffix("/")

    api_key = _member(document, "apiKey", "object", "apiKey") or {}
    mode = _member(api_key, "mode", "string", "apiKey.mode")
    if mode is not None and mode not in ("none", "optional", "required"):
        raise DiscoveryError("apiKey.mode")
    result["apiKeyMode"] = mode or "none"
    key_url = _member(api_key, "url", "string", "apiKey.url")
    result["apiKeyUrl"] = key_url if key_url is not None and url_ok("httpsUrl", key_url) else None

    username = _member(document, "username", "object", "username") or {}
    rules = dict(DEFAULT_USERNAME_RULES)
    for key, low, high in (("minLength", 1, 12), ("maxLength", 12, 32)):
        value = _member(username, key, "integer", f"username.{key}")
        if value is not None:
            rules[key] = min(max(value, low), high)
    charset = _member(username, "charset", "string", "username.charset")
    if charset is not None and charset not in ("unicode", "ascii"):
        raise DiscoveryError("username.charset")
    rules["charset"] = charset or rules["charset"]
    spaces = _member(username, "spaces", "boolean", "username.spaces")
    rules["spaces"] = rules["spaces"] if spaces is None else spaces
    result["username"] = rules

    given = _member(document, "limits", "object", "limits") or {}
    limits = dict(DEFAULT_LIMITS)
    for key, (low, high) in LIMIT_RANGES.items():
        value = _member(given, key, "integer", f"limits.{key}")
        if value is not None:
            limits[key] = min(max(value, low), high)
    limits["heartbeatSeconds"] = max(limits["heartbeatSeconds"], limits["intervalSeconds"])
    result["limits"] = limits

    sections = _member(document, "sections", "array", "sections")
    if sections is not None and not all(isinstance(name, str) for name in sections):
        raise DiscoveryError("sections")
    result["sections"] = [name for name in SECTIONS if sections is None or name in sections]
    enabled = {name: 1 for name in EXTENSIONS if supported(document.get("extensions"), name)}
    if enabled:
        result["extensions"] = enabled
    return result


# ------------------------------------------------------------------------------------------------- service

class StrictJsonError(ValueError):
    pass


def _no_duplicates(pairs):
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise StrictJsonError("duplicate object key")
    return dict(pairs)


def _check_surrogates(value) -> None:
    if isinstance(value, str):
        if any(0xD800 <= ord(ch) <= 0xDFFF for ch in value):
            raise StrictJsonError("lone surrogate")
    elif isinstance(value, dict):
        for key, item in value.items():
            _check_surrogates(key)
            _check_surrogates(item)
    elif isinstance(value, list):
        for item in value:
            _check_surrogates(item)


def strict_json(body: bytes):
    """UTF-8 JSON with no duplicate keys and no lone surrogates (REPORTING 5.4 step 6)."""
    try:
        value = json.loads(body.decode("utf-8"), object_pairs_hook=_no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StrictJsonError(str(error)) from error
    _check_surrogates(value)
    return value


def json_pointer(error: str) -> str:
    """RFC 6901 pointer of the member a schema error is about ("$.run: missing seq" -> "/run/seq")."""
    path, _, detail = error.partition(": ")
    pointer = re.sub(r"\[(\d+)\]", r"/\1", path[1:]).replace(".", "/")
    if detail.startswith("missing "):
        pointer += "/" + detail[len("missing "):]
    elif detail.startswith("unknown property "):
        pointer += "/" + detail[len("unknown property "):]
    return pointer


class TokenBucket:
    def __init__(self, capacity: float, per_second: float):
        self.capacity, self.per_second, self.state = capacity, per_second, {}

    def take(self, key, now: float) -> float:
        """0 when a token was taken, else the seconds until one is available."""
        tokens, last = self.state.get(key, (self.capacity, now))
        tokens = min(self.capacity, tokens + (now - last) * self.per_second)
        if tokens >= 1:
            self.state[key] = (tokens - 1, now)
            return 0.0
        self.state[key] = (tokens, now)
        return (1 - tokens) / self.per_second


class ReferenceService:
    """Every server rule of REPORTING 4, 7 and 8, in memory. handle() is transport independent."""

    def __init__(self, *, authority: str, api_path: str = "", name: str = "Agent Speed reference server",
                 api_key_mode: str = "none", api_keys: tuple = (), rules: dict | None = None,
                 limits: dict | None = None, sections: tuple = SECTIONS, log=None,
                 extensions: dict | None = None):
        self.authority, self.api_path = authority.lower(), api_path.rstrip("/")
        self.name, self.api_key_mode, self.api_keys = name, api_key_mode, set(api_keys)
        self.rules = username_rules(rules)
        self.limits = {**DEFAULT_LIMITS, **(limits or {})}
        self.sections = tuple(sections)
        self.schema = load_schema()
        self.devices: dict[str, dict] = {}
        self.usernames: dict[str, str] = {}
        self.nonces: dict[tuple, float] = {}
        self.seqs: dict[tuple, tuple] = {}
        self.ip_bucket = TokenBucket(60, 1.0)
        self.device_bucket = TokenBucket(3, 0.25)
        self.log = log or (lambda line: None)
        self.extensions = {name: 1 for name in EXTENSIONS if supported(extensions, name)}
        self.extension_state = None
        if self.extensions:
            from report_profile_reference import ProfileExtensions
            self.extension_state = ProfileExtensions(self, sys.modules[__name__])

    # -- documents

    def discovery(self, scheme: str = "https") -> dict:
        api = f"{scheme}://{self.authority}{self.api_path}"
        repo = "https://github.com/zoefix/agent-speed"
        result = {"protocol": "agent-speed-report", "versions": [1],
                "service": {"name": self.name, "description": "Local test server (spec/tools/report_server.py).",
                            "terms": repo, "privacy": repo, "retentionDays": 0},
                "api": api, "apiKey": {"mode": self.api_key_mode}, "username": dict(self.rules),
                "limits": dict(self.limits), "sections": list(self.sections)}
        if self.extensions:
            result["extensions"] = dict(self.extensions)
        return result

    # -- helpers

    @staticmethod
    def _error(status: int, code: str, message: str = "", **extra):
        headers = {}
        if "retryAfterSeconds" in extra:
            headers["Retry-After"] = str(extra["retryAfterSeconds"])
        if code in ("api_key_required", "api_key_invalid"):
            headers["WWW-Authenticate"] = "Bearer"
        body = {"code": code, **({"message": message} if message else {}), **extra}
        return status, headers, {"error": body}

    def _prune(self, now: float) -> None:
        if len(self.nonces) > 10_000 or len(self.seqs) > 10_000 or secrets.randbelow(64) == 0:
            self.nonces = {k: v for k, v in self.nonces.items() if v > now}
            self.seqs = {k: v for k, v in self.seqs.items() if v[1] > now}

    def _claim(self, device_id: str, username: str) -> None:
        self.usernames[username_key(username)] = device_id

    def _release(self, device_id: str) -> None:
        self.usernames = {k: v for k, v in self.usernames.items() if v != device_id}

    # -- entry point

    def handle(self, method: str, path: str, headers: dict, body: bytes, *, client_ip: str = "127.0.0.1",
               now: float | None = None):
        """Returns (status, response headers, JSON body or None). Header names may have any case."""
        now = time.time() if now is None else now
        headers = {k.lower(): v.strip() for k, v in headers.items()}
        self._prune(now)
        if self.ip_bucket.take(client_ip, now):
            return self._error(429, "rate_limited", retryAfterSeconds=5)
        route_path = path.split("?", 1)[0]
        if method == "GET" and route_path == "/.well-known/agent-speed-report":
            return 200, {"Cache-Control": "max-age=3600"}, self.discovery()
        if self.extension_state and method == "GET" and route_path == self.api_path + "/public/users":
            return 200, {}, {"users": self.extension_state.public_users(now)}
        if self.extension_state and method == "GET":
            asset = self.extension_state.public_avatar(route_path)
            if asset is not None:
                return asset
        if not route_path.startswith(self.api_path + "/v1/"):
            return self._error(404, "not_found")
        route = route_path[len(self.api_path):]
        extension_methods = self.extension_state.allowed(route) if self.extension_state else None
        match = re.fullmatch(r"/v1/devices/([0-9a-f-]{36})(/key)?", route)
        if extension_methods:
            allowed = extension_methods
        elif route == "/v1/devices":
            allowed = ("POST",)
        elif route == "/v1/reports":
            allowed = ("POST",)
        elif match and match.group(2):
            allowed = ("PUT",)
        elif match:
            allowed = ("PATCH", "DELETE")
        else:
            return self._error(404, "not_found")
        if method not in allowed:
            return 405, {"Allow": ", ".join(allowed)}, {"error": {"code": "method_not_allowed"}}
        binary_avatar = extension_methods and route == "/v1/profile/avatar" and method == "PUT"
        body_limit = 512 * 1024 if binary_avatar else self.limits["maxBodyBytes"]
        if len(body) > body_limit:
            return self._error(413, "avatar_too_large" if binary_avatar else "payload_too_large")
        field = check_signature_headers(headers)
        if field:
            return self._error(400, "bad_request", "malformed or missing header", field=field)
        timestamp = int(headers["x-agentspeed-timestamp"])
        if abs(now - timestamp) > SKEW_SECONDS:
            return self._error(401, "timestamp_out_of_window", serverTime=int(now))
        authorization = headers.get("authorization", "")
        api_key = authorization[7:] if authorization.startswith("Bearer ") else None
        if self.api_key_mode != "none":
            if api_key is None and self.api_key_mode == "required":
                return self._error(401, "api_key_required")
            if api_key is not None and api_key not in self.api_keys:
                return self._error(401, "api_key_invalid")
        device_id = headers["x-agentspeed-device"]
        document = None
        if body and not binary_avatar:
            try:
                document = strict_json(body)
            except StrictJsonError as error:
                return self._error(400, "bad_request", f"body is not strict UTF-8 JSON: {error}")
            if not isinstance(document, dict):
                return self._error(400, "bad_request", "body is not a JSON object")
        if route == "/v1/devices":
            try:
                pub = parse_jwk((document or {}).get("publicKey"))
            except ValueError as error:
                return self._error(422, "payload_invalid", str(error), field="/publicKey")
        else:
            if match and match.group(1) != device_id:
                return self._error(400, "device_mismatch")
            device = self.devices.get(device_id)
            if device is None:
                return self._error(404, "unknown_device")
            pub = device["pub"]
        if not verify_signature(pub, method, self.authority, path, headers, body):
            return self._error(401, "signature_invalid")
        nonce_key = (device_id, headers["x-agentspeed-nonce"])
        if nonce_key in self.nonces:  # insert-if-absent; handle() runs under one lock, so this is atomic
            return self._error(401, "nonce_replayed")
        self.nonces[nonce_key] = now + NONCE_TTL_SECONDS
        if route != "/v1/devices" and self.api_key_mode != "none":
            bound = self.devices[device_id].get("apiKey")
            if bound is not None and api_key is None:
                return self._error(401, "api_key_required")
            if bound is not None and api_key != bound:
                return self._error(401, "api_key_invalid")
            if bound is None and api_key is not None:
                self.devices[device_id]["apiKey"] = api_key
        if route == "/v1/devices":
            return self._register(device_id, pub, document, api_key, now)
        if extension_methods:
            return self.extension_state.handle(device_id, method, route, headers, body, document, now)
        if route == "/v1/reports":
            return self._report(device_id, headers, body, document, now)
        if match.group(2):
            return self._rotate(device_id, method, path, headers, body, document)
        if method == "PATCH":
            return self._rename(device_id, document)
        return self._delete(device_id)

    # -- endpoints

    def _username_problem(self, username):
        reason = validate_username(username, self.rules)
        if reason:
            return self._error(422, "username_invalid", reason=reason)
        return None

    def _key_owner(self, pub, except_device=None):
        return next((d for d, record in self.devices.items() if record["pub"] == pub and d != except_device), None)

    def _register(self, device_id, pub, document, api_key, now):
        """REPORTING 4.1 order: schema, device id, existing device, username rules, uniqueness or transfer."""
        errors = schema_errors(document, self.schema["$defs"]["registration"], self.schema)
        if errors:
            return self._error(422, "payload_invalid", errors[0], field=json_pointer(errors[0]))
        if document["deviceId"] != device_id:
            return self._error(400, "device_mismatch")
        existing = self.devices.get(device_id)
        if existing:
            if existing["pub"] != pub:
                return self._error(409, "device_conflict")
            return 200, {}, {"status": "exists", "deviceId": device_id, "username": existing["username"]}
        if self._key_owner(pub):
            return self._error(409, "device_conflict", "public key registered for another device")
        username = document["username"]
        problem = self._username_problem(username)
        if problem:
            return problem
        holder = self.usernames.get(username_key(username))
        transferred = False
        if holder is not None:
            holder_key = self.devices[holder].get("apiKey")
            if document.get("transfer") is not True or api_key is None or holder_key != api_key:
                return self._error(409, "username_taken")
            self._release(holder)
            self.devices.pop(holder, None)
            transferred = True
        self.devices[device_id] = {"pub": pub, "username": username, "apiKey": api_key, "created": now,
                                   "client": document["client"], "last": None, "online": False, "totals": {}}
        self._claim(device_id, username)
        self.log(f"register {username!r} device {device_id[:8]} key {thumbprint(pub)[:12]}")
        result = {"status": "created", "deviceId": device_id, "username": username}
        if transferred:
            result["transferred"] = True
        return 201, {}, result

    def _rename(self, device_id, document):
        errors = schema_errors(document, self.schema["$defs"]["rename"], self.schema)
        if errors:
            return self._error(422, "payload_invalid", errors[0], field=json_pointer(errors[0]))
        username = document["username"]
        problem = self._username_problem(username)
        if problem:
            return problem
        device = self.devices[device_id]
        if username == device["username"]:
            return 200, {}, {"status": "unchanged", "username": username}
        holder = self.usernames.get(username_key(username))
        if holder is not None and holder != device_id:
            return self._error(409, "username_taken")
        self._release(device_id)
        device["username"] = username
        self._claim(device_id, username)
        self.log(f"rename device {device_id[:8]} to {username!r}")
        return 200, {}, {"status": "updated", "username": username}

    def _rotate(self, device_id, method, path, headers, body, document):
        """REPORTING 4.5 order: new-key header, schema, new key, new-key signature, unchanged, key in use."""
        header = headers.get("x-agentspeed-new-key-signature", "")
        try:
            if not SIGNATURE_RE.match(header) or len(b64url_decode(header)) != 64:
                raise ValueError
        except ValueError:
            return self._error(400, "bad_request", "malformed or missing header", field="X-AgentSpeed-New-Key-Signature")
        errors = schema_errors(document, self.schema["$defs"]["keyRotation"], self.schema)
        if errors:
            return self._error(422, "payload_invalid", errors[0], field=json_pointer(errors[0]))
        try:
            new_pub = parse_jwk(document["publicKey"])
        except ValueError as error:
            return self._error(422, "payload_invalid", str(error), field="/publicKey")
        if not verify_signature(new_pub, method, self.authority, path, headers, body, "x-agentspeed-new-key-signature"):
            return self._error(401, "signature_invalid", "new key signature", field="X-AgentSpeed-New-Key-Signature")
        if new_pub == self.devices[device_id]["pub"]:
            return 200, {}, {"status": "unchanged"}
        if self._key_owner(new_pub, except_device=device_id):
            return self._error(409, "device_conflict", "public key registered for another device")
        self.devices[device_id]["pub"] = new_pub
        self.log(f"rotate device {device_id[:8]} to key {thumbprint(new_pub)[:12]}")
        return 200, {}, {"status": "rotated"}

    def _delete(self, device_id):
        if self.extension_state:
            self.extension_state.delete_device(device_id)
        self._release(device_id)
        device = self.devices.pop(device_id)
        self.nonces = {k: v for k, v in self.nonces.items() if k[0] != device_id}
        self.seqs = {k: v for k, v in self.seqs.items() if k[0] != device_id}
        self.log(f"forget {device['username']!r} device {device_id[:8]}: device, username and reports deleted")
        return 200, {}, {"status": "deleted"}

    def _report(self, device_id, headers, body, document, now):
        if document is None:
            return self._error(400, "bad_request", "empty body")
        if "schema" not in document:
            return self._error(422, "payload_invalid", "missing schema", field="/schema")
        if document["schema"] != 1:
            return self._error(400, "version_unsupported", supported=[1])
        errors = schema_errors(document, self.schema["$defs"]["report"], self.schema)
        if errors:
            return self._error(422, "payload_invalid", errors[0], field=json_pointer(errors[0]))
        extension_errors = report_extension_errors(document, self.extensions)
        if extension_errors:
            field, reason = extension_errors[0]
            return self._error(422, "payload_invalid", reason, field=field)
        device = self.devices[device_id]
        if document["deviceId"] != device_id:
            return self._error(400, "device_mismatch")
        if document["username"] != device["username"]:
            return self._error(409, "username_mismatch", username=device["username"])
        age_ms = int(headers["x-agentspeed-timestamp"]) * 1000 - parse_instant(document["sentAt"])
        if age_ms > (self.limits["maxAgeSeconds"] + 5) * 1000 or age_ms < -2000:
            return self._error(422, "report_stale")
        key = (device_id, document["run"]["id"], document["run"]["seq"])
        digest = sha256_hex(body)
        if key in self.seqs:
            if self.seqs[key][0] == digest:
                return 200, {}, {"status": "duplicate"}
            return self._error(409, "seq_conflict")
        wait = self.device_bucket.take(device_id, now)
        if wait:
            return self._error(429, "rate_limited", retryAfterSeconds=max(1, int(wait + 0.999)))
        self.seqs[key] = (digest, now + SEQ_TTL_SECONDS)  # recorded together with the acceptance
        totals = device["totals"]
        for field, value in document["delta"].items():
            totals[field] = totals.get(field, 0) + value
        if "cost" in document:
            totals["costMicroUsd"] = totals.get("costMicroUsd", 0) + document["cost"]["deltaMicroUsd"]
        device.update(last=document, lastAt=now, online=document["activity"] != "leaving")
        if self.extension_state:
            self.extension_state.record_report(device_id, document, now)
        self.log(report_line(document))
        return 200, {}, {"status": "accepted"}

    # -- presence

    def online(self, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        grace = 2 * self.limits["heartbeatSeconds"] + 10
        return [d for d in self.devices.values() if d["online"] and now - d.get("lastAt", 0) <= grace]


def report_line(report: dict) -> str:
    cost = report.get("cost")
    traffic = report.get("traffic") or {}
    parts = [time.strftime("%H:%M:%S", time.gmtime(parse_instant(report["sentAt"]) / 1000)),
             f"{report['username']:<20}", f"{report['activity']:<7}", f"seq {report['run']['seq']:<5}",
             f"{report['live']['outputTokS']:>8.1f} tok/s", f"+{report['delta']['output']} out",
             f"agents {report['live']['agents']['generating']}/{report['live']['agents']['tools']}"]
    if cost:
        parts.append(f"+US${cost['deltaMicroUsd'] / 1e6:.6f}")
    if traffic.get("status") == "ok" and traffic.get("rxBytesPerSecond") is not None:
        parts.append(f"down {traffic['rxBytesPerSecond'] / 1000:.1f} KB/s")
    return "  ".join(parts)


# ------------------------------------------------------------------------------------------------- scheduler

HOLD_MS = 15_000
QUIET_MS = 600_000
GAP_MS = 15_000
RETRY_MS = 2_000


def backoff_ms(failures: int) -> int:
    return 0 if failures < 2 else min(300_000, 5_000 * 2 ** (failures - 2))


def _tick_times(ranges) -> list[int]:
    return [t for start, end in ranges for t in range(start, end + 1, 500)]


def _in_ranges(t: int, ranges) -> bool:
    return any(start <= t <= end for start, end in ranges)


def simulate_scheduler(case: dict) -> dict:
    """METRICS 11.5 with instant sends; outcomes come from the case. Returns delivered and lost reports."""
    config = {**DEFAULT_LIMITS, **case.get("config", {})}
    interval, heartbeat_ms = config["intervalSeconds"] * 1000, config["heartbeatSeconds"] * 1000
    max_age = config["maxAgeSeconds"] * 1000
    increments: dict[int, int] = {}
    for spec in case.get("increments", []):
        for t in range(spec["from"], spec["to"] + 1, spec["step"]):
            increments[t] = increments.get(t, 0) + spec["output"]
    events: dict[int, list] = {}
    for t, name in case.get("events", []):
        events.setdefault(t, []).append(name)
    outcomes = {int(k): list(v) for k, v in case.get("outcomes", {}).items()}
    delivered, lost = [], []
    st = {"seq": 0, "ledger": 0, "windowStart": None, "lastActive": None, "mode": "quiet", "prev": None,
          "backoff": -1, "retryAfter": -1, "failures": 0, "paused": False, "networkOff": False,
          "inflight": None, "waiting": None}

    def outcome_for(report):
        queue = outcomes.get(report["seq"], [])
        return queue[report["attempts"]] if report["attempts"] < len(queue) else "ok"

    def build(t, activity):
        st["seq"] += 1
        report = {"seq": st["seq"], "end": t, "windowMs": t - st["windowStart"], "activity": activity,
                  "output": st["ledger"], "builtAt": t, "attempts": 0, "nextAt": t}
        st["ledger"], st["windowStart"] = 0, t
        return report

    def fail(report, t):
        lost.append(report["seq"])
        st["failures"] += 1
        st["backoff"] = max(st["backoff"], t + backoff_ms(st["failures"]))

    def attempt(report, t, single=False):
        result = outcome_for(report)
        report["attempts"] += 1
        if result == "ok":
            delivered.append([report["seq"], report["end"], report["windowMs"], report["activity"], report["output"]])
            st["failures"] = 0
            return None
        if result.startswith("rateLimited:"):
            lost.append(report["seq"])
            st["retryAfter"] = max(st["retryAfter"], t + int(result.split(":")[1]) * 1000)
            return None
        if not single and report["attempts"] < 2 and t + RETRY_MS - report["builtAt"] <= max_age:
            report["nextAt"] = t + RETRY_MS
            return report
        fail(report, t)
        return None

    def drop_outbox():
        for key in ("inflight", "waiting"):
            if st[key] is not None:
                lost.append(st[key]["seq"])
                st[key] = None

    for t in _tick_times(case["ticks"]):
        just_paused = False
        for name in events.get(t, []):
            if name == "pause":
                just_paused = not st["paused"]
                st["paused"] = True
            elif name == "resume":
                st["paused"] = False
            elif name == "networkOff":
                st["networkOff"] = True
                drop_outbox()
            elif name == "networkOn":
                st["networkOff"] = False
        if st["prev"] is not None and t - st["prev"] > GAP_MS:
            st["ledger"], st["windowStart"] = 0, t
        if st["windowStart"] is None:
            st["windowStart"] = t
        st["ledger"] += increments.get(t, 0)
        if _in_ranges(t, case.get("activity", [])):
            st["lastActive"] = t
        since = None if st["lastActive"] is None else t - st["lastActive"]
        mode = "quiet" if since is None or since >= QUIET_MS else ("active" if since < HOLD_MS else "idle")
        previous_mode, st["prev"] = st["mode"], t
        st["mode"] = mode
        # Step 4: a backoff does not stop the leaving report; the network switch and a Retry-After wait do.
        if just_paused and previous_mode != "quiet" and not st["networkOff"] and t >= st["retryAfter"]:
            if st["inflight"] is not None:
                fail(st["inflight"], t)
                st["inflight"] = None
            if st["waiting"] is not None:
                lost.append(st["waiting"]["seq"])
                st["waiting"] = None
            attempt(build(t, "leaving"), t, single=True)
        if st["paused"] or st["networkOff"] or t < max(st["backoff"], st["retryAfter"]):
            st["ledger"], st["windowStart"] = 0, t
            continue
        if mode == "quiet":
            if previous_mode in ("active", "idle"):
                st["waiting"] = build(t, "leaving")
            else:
                st["ledger"], st["windowStart"] = 0, t
        elif t - st["windowStart"] >= (interval if mode == "active" else heartbeat_ms):
            report = build(t, mode)
            if st["inflight"] is not None and st["inflight"]["nextAt"] > t:
                fail(st["inflight"], t)
                st["inflight"] = None
            if st["waiting"] is not None:
                lost.append(st["waiting"]["seq"])
            st["waiting"] = report
        if st["inflight"] is None and st["waiting"] is not None:
            st["inflight"], st["waiting"] = st["waiting"], None
        report = st["inflight"]
        if report is not None and report["nextAt"] <= t:
            if t - report["builtAt"] > max_age:
                fail(report, t)
                st["inflight"] = None
            else:
                st["inflight"] = attempt(report, t)
    return {"delivered": delivered, "lost": sorted(lost)}


# ------------------------------------------------------------------------------------------------- vectors

DEVICE_ID = "6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b"
OTHER_DEVICE_ID = "0b7e4d2c-9a1f-4c3e-b5d6-7e8f9a0b1c2d"
THIRD_DEVICE_ID = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
API_BASE = "https://api.example.com/agent-speed"
T0 = 1792656931  # 2026-10-22T08:15:31Z

RFC6979 = {
    "comment": "RFC 6979 A.2.5 (P-256, SHA-256): checks deterministic signing; apps check only verification.",
    "d": "C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721",
    "x": "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6",
    "y": "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299",
    "messages": [
        {"message": "sample", "r": "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716",
         "s": "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8"},
        {"message": "test", "r": "F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367",
         "s": "019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083"},
    ],
}

KEY_LABELS = {"device": "agent-speed report vector key 1", "other": "agent-speed report vector key 2",
              "rotated": "agent-speed report vector key 3"}


def _keys() -> dict:
    keys = {}
    for name, label in KEY_LABELS.items():
        d = test_private_key(label)
        pub = public_key(d)
        keys[name] = {"d": f"{d:064x}", "jwk": jwk(pub), "spki": b64url(spki(pub)), "thumbprint": thumbprint(pub)}
    return keys


def load_examples() -> dict:
    return {path.stem: json.loads(path.read_text(encoding="utf-8")) for path in sorted(EXAMPLES_DIR.glob("*.json"))}


def _request(key: int, method: str, url: str, device_id: str, body: bytes, timestamp: int, nonce: str, **extra) -> dict:
    headers = signed_headers(key, method, url, device_id, body, timestamp=timestamp, nonce=nonce,
                             version="1.3.0", **extra)
    canonical = canonical_string(method, authority_of(url), path_of(url), str(timestamp), nonce, device_id, body)
    return {"method": method, "url": url, "authority": authority_of(url), "path": path_of(url),
            "headers": headers, "body": body.decode("utf-8"), "bodySha256": sha256_hex(body),
            "canonical": canonical}


def _nonce(label: str) -> str:
    return b64url(hashlib.sha256(label.encode()).digest()[:16])


def _registration(device_id: str, username: str, pub, platform: str = "macOS", transfer: bool = False) -> bytes:
    document = {"schema": 1, "deviceId": device_id, "username": username, "publicKey": jwk(pub),
                "client": {"app": "AgentSpeed", "version": "1.3.0", "platform": platform,
                           "osMajor": 27 if platform == "macOS" else 11}}
    if transfer:
        document["transfer"] = True
    return compact_json(document)


def build_vectors() -> dict:
    keys = _keys()
    d1, d2, d3 = (int(keys[name]["d"], 16) for name in ("device", "other", "rotated"))
    p1, p2, p3 = public_key(d1), public_key(d2), public_key(d3)
    examples = load_examples()
    report_body = compact_json(examples["report-active"])
    requests = {
        "register": _request(d1, "POST", f"{API_BASE}/v1/devices", DEVICE_ID,
                             _registration(DEVICE_ID, "zoe-mbp", p1), T0, _nonce("register")),
        "report": _request(d1, "POST", f"{API_BASE}/v1/reports", DEVICE_ID, report_body, T0, _nonce("report")),
        "rename": _request(d1, "PATCH", f"{API_BASE}/v1/devices/{DEVICE_ID}", DEVICE_ID,
                           compact_json({"username": "小明的 Mac"}), T0, _nonce("rename")),
        "rotate": _request(d1, "PUT", f"{API_BASE}/v1/devices/{DEVICE_ID}/key", DEVICE_ID,
                           compact_json({"publicKey": jwk(p3)}), T0, _nonce("rotate"), new_key=d3),
        "delete": _request(d1, "DELETE", f"{API_BASE}/v1/devices/{DEVICE_ID}", DEVICE_ID, b"", T0, _nonce("delete")),
        "loopback": _request(d1, "POST", "http://127.0.0.1:8787/v1/reports", DEVICE_ID,
                             compact_json({**examples["report-minimal"], "deviceId": DEVICE_ID,
                                           "username": "zoe-mbp"}), T0, _nonce("loopback")),
    }
    for request in requests.values():
        raw = b64url_decode(request["headers"]["X-AgentSpeed-Signature"])
        request["signatureDer"] = b64url(der_signature(raw))
        request["highS"] = int.from_bytes(raw[32:], "big") > N // 2

    signature = b64url_decode(requests["report"]["headers"]["X-AgentSpeed-Signature"])
    r, s = int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
    other_s = b64url(r.to_bytes(32, "big") + (N - s).to_bytes(32, "big"))
    original = requests["report"]["headers"]["X-AgentSpeed-Signature"]
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    loose = original[:-1] + alphabet[alphabet.index(original[-1]) | 1]
    canonical = requests["report"]["canonical"]

    def resign(text: str) -> str:
        return b64url(sign(d1, text.encode("utf-8")))

    lines = canonical.split("\n")
    upper_hex = "\n".join(lines[:-1] + [lines[-1].upper()])
    verify_cases = [
        {"name": f"{name} is valid", "request": name, "key": "device", "expect": "valid"} for name in requests
    ] + [
        {"name": "rotate: new-key signature is valid", "request": "rotate", "key": "rotated",
         "header": "X-AgentSpeed-New-Key-Signature", "expect": "valid"},
        {"name": "tampered body", "request": "report", "key": "device",
         "change": {"body": requests["report"]["body"].replace('"output":1840', '"output":1841')}, "expect": "invalid"},
        {"name": "timestamp changed", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Timestamp": str(T0 + 1)}}, "expect": "invalid"},
        {"name": "nonce changed", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Nonce": _nonce("other")}}, "expect": "invalid"},
        {"name": "device header changed", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Device": OTHER_DEVICE_ID}}, "expect": "invalid"},
        {"name": "path changed", "request": "report", "key": "device",
         "change": {"path": "/agent-speed/v1/reports/"}, "expect": "invalid"},
        {"name": "authority changed", "request": "report", "key": "device",
         "change": {"authority": "api.example.org"}, "expect": "invalid"},
        {"name": "method changed", "request": "rename", "key": "device", "change": {"method": "PUT"},
         "expect": "invalid"},
        {"name": "wrong public key", "request": "report", "key": "other", "expect": "invalid"},
        {"name": f"s replaced by n - s is valid too (the original is {'high' if requests['report']['highS'] else 'low'}"
                 "-S; servers must accept both)", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": other_s}}, "expect": "valid"},
        {"name": "non-zero trailing bits in the last base64url character are malformed", "request": "report",
         "key": "device", "change": {"headers": {"X-AgentSpeed-Signature": loose}}, "expect": "malformed"},
        {"name": "DER signature is malformed", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": requests["report"]["signatureDer"]}}, "expect": "malformed"},
        {"name": "padded base64url is malformed", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": requests["report"]["headers"]["X-AgentSpeed-Signature"]
                                + "=="}}, "expect": "malformed"},
        {"name": "r = 0", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": b64url(bytes(32) + s.to_bytes(32, "big"))}},
         "expect": "invalid"},
        {"name": "s = n", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": b64url(r.to_bytes(32, "big") + N.to_bytes(32, "big"))}},
         "expect": "invalid"},
        {"name": "signed with a trailing newline", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": resign(canonical + "\n")}}, "expect": "invalid"},
        {"name": "signed the SHA-256 digest instead of the message (hashed twice)", "request": "report",
         "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": resign_digest(d1, canonical)}}, "expect": "invalid"},
        {"name": "body hash in upper-case hex", "request": "report", "key": "device",
         "change": {"headers": {"X-AgentSpeed-Signature": resign(upper_hex)}}, "expect": "invalid"},
    ]
    bad_point = dict(keys["device"]["jwk"])
    y = int.from_bytes(b64url_decode(bad_point["y"]), "big")
    bad_point["y"] = b64url(((y + 1) % P).to_bytes(32, "big"))
    key_cases = [
        {"name": "valid key", "jwk": keys["device"]["jwk"], "expect": "valid"},
        {"name": "point not on the curve", "jwk": bad_point, "expect": "invalid"},
        {"name": "padded coordinate", "jwk": {**keys["device"]["jwk"], "x": keys["device"]["jwk"]["x"] + "="},
         "expect": "invalid"},
        {"name": "wrong curve", "jwk": {**keys["device"]["jwk"], "crv": "P-384"}, "expect": "invalid"},
        {"name": "x not below p (32 bytes, unreduced)", "jwk": {**keys["device"]["jwk"],
                                                               "x": b64url(P.to_bytes(32, "big"))}, "expect": "invalid"},
        {"name": "42-character coordinate", "jwk": {**keys["device"]["jwk"], "x": keys["device"]["jwk"]["x"][:42]},
         "expect": "invalid"},
        {"name": "44-character coordinate", "jwk": {**keys["device"]["jwk"], "x": keys["device"]["jwk"]["x"] + "A"},
         "expect": "invalid"},
        {"name": "public key that contains the private d", "jwk": {**keys["device"]["jwk"],
                                                                    "d": b64url(d1.to_bytes(32, "big"))},
         "expect": "invalid"},
    ]
    return {
        "_comment": "REPORTING 5 and METRICS 11 vectors, written by spec/tools/report_reference.py --write and checked "
                    "by running it without arguments. Signatures are deterministic (RFC 6979) so the file is "
                    "reproducible; real clients may sign with random k, so apps compare by verifying, not by bytes. "
                    "Header names are case-insensitive; bodies are the exact UTF-8 bytes sent.",
        "schema": 1,
        "algorithm": {"name": "ES256", "curve": "P-256", "hash": "SHA-256", "signature": "IEEE P1363 r || s, 64 bytes",
                      "encoding": "base64url without padding", "label": LABEL},
        "rfc6979": RFC6979,
        "keys": keys,
        "requests": requests,
        "verify": verify_cases,
        "publicKeys": key_cases,
        "server": build_server_cases(d1, d2, d3, p1, p2, p3, examples),
        "usernames": USERNAME_CASES,
        "scheduler": SCHEDULER_CASES,
        "discovery": DISCOVERY_CASES,
    }


def resign_digest(d: int, canonical: str) -> str:
    return b64url(sign(d, hashlib.sha256(canonical.encode("utf-8")).digest()))


def _step(at, key, method, url, device_id, body, nonce_label, expect, **extra):
    request = _request(key, method, url, device_id, body, extra.pop("timestamp", at), _nonce(nonce_label), **extra)
    return {"at": at, "request": {k: request[k] for k in ("method", "path", "headers", "body")}, "expect": expect}


def _report_body(examples, **changes) -> bytes:
    report = copy.deepcopy(examples["report-active"])
    for path, value in changes.items():
        target = report
        parts = path.split(".")
        for part in parts[:-1]:
            target = target[part]
        target[parts[-1]] = value
    return compact_json(report)


def build_server_cases(d1, d2, d3, p1, p2, p3, examples) -> list:
    devices, reports = f"{API_BASE}/v1/devices", f"{API_BASE}/v1/reports"
    one = f"{devices}/{DEVICE_ID}"
    t = T0
    first_report = _report_body(examples)
    lifecycle = [
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "s1",
              {"status": 201, "result": "created"}),
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "s2",
              {"status": 200, "result": "exists"}),
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "x", p1), "s2b",
              {"status": 200, "result": "exists"}),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "Zoe-MBP", p2), "s3",
              {"status": 409, "code": "username_taken"}),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "ｚｏｅ-mbp", p2), "s4",
              {"status": 422, "code": "username_invalid", "reason": "characters"}),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "x", p2), "s5",
              {"status": 422, "code": "username_invalid", "reason": "length"}),
        _step(t, d2, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p2), "s6",
              {"status": 409, "code": "device_conflict"}),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "racer-7k3m9q", p2, "Windows"),
              "s7", {"status": 201, "result": "created"}),
        _step(t, d1, "POST", reports, DEVICE_ID, first_report, "s8", {"status": 200, "result": "accepted"}),
    ]
    lifecycle.append(copy.deepcopy(lifecycle[-1]))
    lifecycle[-1]["at"] = t + 1
    lifecycle[-1]["expect"] = {"status": 401, "code": "nonce_replayed"}
    lifecycle += [
        _step(t + 2, d1, "POST", reports, DEVICE_ID, first_report, "s10", {"status": 200, "result": "duplicate"}),
        _step(t + 2, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"windowMs": 5001}), "s11",
              {"status": 409, "code": "seq_conflict"}),
        _step(t + 3, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 43}), "s12",
              {"status": 401, "code": "timestamp_out_of_window"}, timestamp=t + 3 - 301),
        _step(t + 3, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 43}), "s13",
              {"status": 401, "code": "timestamp_out_of_window"}, timestamp=t + 3 + 301),
        _step(t + 3, d2, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 43}), "s14",
              {"status": 401, "code": "signature_invalid"}),
        _step(t + 3, d3, "POST", reports, THIRD_DEVICE_ID, _report_body(examples, **{"deviceId": THIRD_DEVICE_ID}),
              "s15", {"status": 404, "code": "unknown_device"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 44, "username": "zoe"}),
              "s16", {"status": 409, "code": "username_mismatch", "username": "zoe-mbp"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 45, "schema": 2}), "s17",
              {"status": 400, "code": "version_unsupported"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID,
              _report_body(examples, **{"run.seq": 46, "sentAt": format_instant((t - 60) * 1000)}), "s18",
              {"status": 422, "code": "report_stale"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 47, "activity": "busy"}),
              "s19", {"status": 422, "code": "payload_invalid", "field": "/activity"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID,
              _report_body(examples, **{"run.seq": 51}).replace(b'"windowMs":5000', b'"windowMs":5000,"windowMs":5000'),
              "s19b", {"status": 400, "code": "bad_request"}),
        _step(t + 4, d1, "POST", reports, DEVICE_ID, compact_json({k: v for k, v in json.loads(
            _report_body(examples, **{"run.seq": 52})).items() if k != "schema"}), "s19c",
              {"status": 422, "code": "payload_invalid", "field": "/schema"}),
        _step(t + 5, d1, "PATCH", one, DEVICE_ID, compact_json({"username": "Racer-7K3M9Q"}), "s20",
              {"status": 409, "code": "username_taken"}),
        _step(t + 5, d2, "PATCH", f"{devices}/{OTHER_DEVICE_ID}", OTHER_DEVICE_ID,
              compact_json({"username": "Racer-7K3M9Q"}), "s20b", {"status": 200, "result": "updated"}),
        _step(t + 5, d1, "PATCH", one, DEVICE_ID, compact_json({"username": "小明的 Mac"}), "s21",
              {"status": 200, "result": "updated"}),
        _step(t + 6, d1, "PUT", f"{one}/key", DEVICE_ID, compact_json({"publicKey": jwk(p3)}), "s22",
              {"status": 200, "result": "rotated"}, new_key=d3),
        _step(t + 6, d3, "PUT", f"{one}/key", DEVICE_ID, compact_json({"publicKey": jwk(p3)}), "s22b",
              {"status": 200, "result": "unchanged"}, new_key=d3),
        _step(t + 7, d1, "POST", reports, DEVICE_ID,
              _report_body(examples, **{"run.seq": 48, "username": "小明的 Mac"}), "s23",
              {"status": 401, "code": "signature_invalid"}),
        _step(t + 7, d3, "POST", reports, DEVICE_ID,
              _report_body(examples, **{"run.seq": 49, "username": "小明的 Mac"}), "s24",
              {"status": 200, "result": "accepted"}),
        _step(t + 8, d3, "DELETE", one, DEVICE_ID, b"", "s25", {"status": 200, "result": "deleted"}),
        _step(t + 8, d3, "POST", reports, DEVICE_ID,
              _report_body(examples, **{"run.seq": 50, "username": "小明的 Mac"}), "s26",
              {"status": 404, "code": "unknown_device"}),
        _step(t + 9, d2, "PATCH", f"{devices}/{OTHER_DEVICE_ID}", OTHER_DEVICE_ID,
              compact_json({"username": "小明的 mac"}), "s27", {"status": 200, "result": "updated"}),
    ]
    burst = [_step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "b0",
                   {"status": 201, "result": "created"})]
    for index in range(4):
        expect = {"status": 200, "result": "accepted"} if index < 3 else {"status": 429, "code": "rate_limited"}
        burst.append(_step(t, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 42 + index}),
                           f"b{index + 1}", expect))
    burst.append(_step(t + 4, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"run.seq": 46}), "b5",
                       {"status": 200, "result": "accepted"}))
    key_a, key_b = "test-key-123456", "test-key-654321"
    second = _report_body(examples, **{"deviceId": OTHER_DEVICE_ID})
    keyed = [
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "k1",
              {"status": 401, "code": "api_key_required"}),
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "k2",
              {"status": 401, "code": "api_key_invalid"}, api_key="wrong-key-000"),
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "k3",
              {"status": 201, "result": "created"}, api_key=key_a),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "zoe-mbp", p2), "k4",
              {"status": 409, "code": "username_taken"}, api_key=key_a),
        _step(t, d2, "POST", devices, OTHER_DEVICE_ID, _registration(OTHER_DEVICE_ID, "zoe-mbp", p2, transfer=True),
              "k5", {"status": 201, "result": "created", "transferred": True}, api_key=key_a),
        _step(t, d1, "POST", reports, DEVICE_ID, first_report, "k6", {"status": 404, "code": "unknown_device"},
              api_key=key_a),
        _step(t, d2, "POST", reports, OTHER_DEVICE_ID, second, "k7", {"status": 401, "code": "api_key_invalid"},
              api_key=key_b),
        _step(t, d2, "POST", reports, OTHER_DEVICE_ID, second, "k8", {"status": 200, "result": "accepted"},
              api_key=key_a),
    ]
    large = _report_body(examples, **{"username": "zoe-mbp", "padding": "x" * 17_000})
    size = [
        _step(t, d1, "POST", devices, DEVICE_ID, _registration(DEVICE_ID, "zoe-mbp", p1), "z1",
              {"status": 201, "result": "created"}),
        _step(t, d1, "POST", reports, DEVICE_ID, large, "z2", {"status": 413, "code": "payload_too_large"}),
        _step(t, d1, "POST", reports, DEVICE_ID, _report_body(examples, **{"futureField": {"a": 1}}), "z3",
              {"status": 200, "result": "accepted"}),
    ]
    base = {"authority": "api.example.com", "apiPath": "/agent-speed",
            "policies": {"reportBurst": 3, "reportRefillSeconds": 4, "transfer": True}}
    return [
        {"name": "lifecycle, replay and errors", "config": base, "steps": lifecycle},
        {"name": "per-device rate limit (policy: burst 3, then one accepted report per 4 s)", "config": base,
         "steps": burst},
        {"name": "API key required; a device is bound to its account; an explicit transfer moves the username "
                 "(policy: transfer allowed)", "config": {**base, "apiKey": "required", "apiKeys": [key_a, key_b]},
         "steps": keyed},
        {"name": "body size limit; unknown fields are ignored", "config": base, "steps": size},
    ]


USERNAME_CASES = {
    "rules": {
        "default": DEFAULT_USERNAME_RULES,
        "strict": {"minLength": 3, "maxLength": 16, "charset": "ascii", "spaces": False},
    },
    "validate": [
        {"name": "zoe-mbp", "rules": "default", "expect": None},
        {"name": "小明的 Mac", "rules": "default", "expect": None},
        {"name": "Zoë Studio", "rules": "default", "expect": None},
        {"name": "x", "rules": "default", "expect": "length"},
        {"name": "abcdefghijklmnopqrstuvwxyz0123456", "rules": "default", "expect": "length"},
        {"name": "-zoe", "rules": "default", "expect": "start"},
        {"name": "zoe ", "rules": "default", "expect": "spaces"},
        {"name": "zoe  mbp", "rules": "default", "expect": "spaces"},
        {"name": "zoe\tmbp", "rules": "default", "expect": "spaces"},
        {"name": "zoe🚀", "rules": "default", "expect": "characters"},
        {"name": "zoe@home", "rules": "default", "expect": "characters"},
        {"name": "ｚｏｅ", "rules": "default", "expect": "characters"},
        {"name": "zoe\u200bmbp", "rules": "default", "expect": "characters"},
        {"name": "zq\u0301\u0302\u0303\u0304e", "rules": "default", "expect": None},
        {"name": "zq\u0301\u0302\u0303\u0304\u0305e", "rules": "default", "expect": "characters"},
        {"name": "\u0645\u0631\u062d\u0628\u0627", "rules": "default", "expect": None},
        {"name": "Zoe MBP", "rules": "strict", "expect": "spaces"},
        {"name": "小明的家", "rules": "strict", "expect": "characters"},
        {"name": "ab", "rules": "strict", "expect": "length"},
        {"name": "racer-7k3m9q", "rules": "strict", "expect": None},
    ],
    "fit": [
        {"computerName": "Zoe’s MacBook Pro", "rules": "default", "expect": "Zoes MacBook Pro"},
        {"computerName": "Zoe’s MacBook Pro", "rules": "strict", "expect": "Zoes-MacBook-Pro"},
        {"computerName": "小明的 MacBook Air", "rules": "default", "expect": "小明的 MacBook Air"},
        {"computerName": "小明的 MacBook Air", "rules": "strict", "expect": "MacBook-Air"},
        {"computerName": "DESKTOP-7Q2K1LM", "rules": "strict", "expect": "DESKTOP-7Q2K1LM"},
        {"computerName": "José’s PC", "rules": "strict", "expect": "Joses-PC"},
        {"computerName": "MacBook Pro (2)", "rules": "default", "expect": "MacBook Pro 2"},
        {"computerName": "MacBook Pro (2)", "rules": "strict", "expect": "MacBook-Pro-2"},
        {"computerName": "Zoë – Studio", "rules": "default", "expect": "Zoë Studio"},
        {"computerName": "ＭａｃＢｏｏｋ", "rules": "strict", "expect": "MacBook"},
        {"computerName": "Workstation of the Platform Team", "rules": "strict", "expect": "Workstation-of-t"},
        {"computerName": "🚀🚀", "rules": "default", "expect": None},
        {"computerName": "  ", "rules": "strict", "expect": None},
    ],
    "keys": [
        {"a": "Zoe-MBP", "b": "zoe-mbp", "same": True},
        {"a": "Straße", "b": "STRASSE", "same": True},
        {"a": "小明的 Mac", "b": "小明的 mac", "same": True},
        {"a": "zoe-mbp", "b": "zoe_mbp", "same": False},
    ],
}

_STEADY = {"from": 1000, "to": 29000, "step": 1000, "output": 100}
SCHEDULER_CASES = [
    {
        "name": "steady activity, then idle heartbeats, then quiet",
        "ticks": [[0, 700000]], "activity": [[0, 29500]], "increments": [_STEADY],
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [2, 10000, 5000, "active", 500],
                                 [3, 15000, 5000, "active", 500], [4, 20000, 5000, "active", 500],
                                 [5, 25000, 5000, "active", 500], [6, 30000, 5000, "active", 400],
                                 [7, 35000, 5000, "active", 0], [8, 40000, 5000, "active", 0],
                                 [9, 100000, 60000, "idle", 0], [10, 160000, 60000, "idle", 0],
                                 [11, 220000, 60000, "idle", 0], [12, 280000, 60000, "idle", 0],
                                 [13, 340000, 60000, "idle", 0], [14, 400000, 60000, "idle", 0],
                                 [15, 460000, 60000, "idle", 0], [16, 520000, 60000, "idle", 0],
                                 [17, 580000, 60000, "idle", 0], [18, 629500, 49500, "leaving", 0]],
                   "lost": []},
    },
    {
        "name": "a report that fails twice is lost; the next window starts where it ended",
        "ticks": [[0, 40000]], "activity": [[0, 40000]],
        "increments": [{"from": 1000, "to": 40000, "step": 1000, "output": 100}],
        "outcomes": {"2": ["fail", "fail"]},
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [3, 15000, 5000, "active", 500],
                                 [4, 20000, 5000, "active", 500], [5, 25000, 5000, "active", 500],
                                 [6, 30000, 5000, "active", 500], [7, 35000, 5000, "active", 500],
                                 [8, 40000, 5000, "active", 500]],
                   "lost": [2]},
    },
    {
        "name": "one retry after 2 s sends the same report",
        "ticks": [[0, 20000]], "activity": [[0, 20000]],
        "increments": [{"from": 1000, "to": 20000, "step": 1000, "output": 100}],
        "outcomes": {"2": ["fail", "ok"]},
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [2, 10000, 5000, "active", 500],
                                 [3, 15000, 5000, "active", 500], [4, 20000, 5000, "active", 500]],
                   "lost": []},
    },
    {
        "name": "429 with Retry-After 20: usage during the wait is never reported",
        "ticks": [[0, 60000]], "activity": [[0, 60000]],
        "increments": [{"from": 1000, "to": 60000, "step": 1000, "output": 100}],
        "outcomes": {"2": ["rateLimited:20"]},
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [3, 34500, 5000, "active", 500],
                                 [4, 39500, 5000, "active", 500], [5, 44500, 5000, "active", 500],
                                 [6, 49500, 5000, "active", 500], [7, 54500, 5000, "active", 500],
                                 [8, 59500, 5000, "active", 500]],
                   "lost": [2]},
    },
    {
        "name": "a tick gap over 15 s (sleep) discards the open window",
        "ticks": [[0, 22000], [80000, 100000]], "activity": [[0, 22000], [80000, 100000]],
        "increments": [{"from": 1000, "to": 22000, "step": 1000, "output": 100},
                       {"from": 81000, "to": 100000, "step": 1000, "output": 100}],
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [2, 10000, 5000, "active", 500],
                                 [3, 15000, 5000, "active", 500], [4, 20000, 5000, "active", 500],
                                 [5, 85000, 5000, "active", 500], [6, 90000, 5000, "active", 500],
                                 [7, 95000, 5000, "active", 500], [8, 100000, 5000, "active", 500]],
                   "lost": []},
    },
    {
        "name": "pause sends a leaving report; resume starts a new window",
        "ticks": [[0, 40000]], "activity": [[0, 40000]],
        "increments": [{"from": 1000, "to": 40000, "step": 1000, "output": 100}],
        "events": [[12000, "pause"], [30000, "resume"]],
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [2, 10000, 5000, "active", 500],
                                 [3, 12000, 2000, "leaving", 200], [4, 34500, 5000, "active", 500],
                                 [5, 39500, 5000, "active", 500]],
                   "lost": []},
    },
    {
        "name": "network switched off: no leaving report, nothing sent until it is back",
        "ticks": [[0, 30000]], "activity": [[0, 30000]],
        "increments": [{"from": 1000, "to": 30000, "step": 1000, "output": 100}],
        "events": [[12000, "networkOff"], [20000, "networkOn"]],
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [2, 10000, 5000, "active", 500],
                                 [3, 24500, 5000, "active", 500], [4, 29500, 5000, "active", 500]],
                   "lost": []},
    },
    {
        "name": "activity after idle sends at once, then every 5 s",
        "ticks": [[0, 200000]], "activity": [[0, 2000], [150000, 160000]],
        "increments": [{"from": 2000, "to": 2000, "step": 1000, "output": 100},
                       {"from": 155000, "to": 155000, "step": 1000, "output": 300}],
        "expect": {"delivered": [[1, 5000, 5000, "active", 100], [2, 10000, 5000, "active", 0],
                                 [3, 15000, 5000, "active", 0], [4, 75000, 60000, "idle", 0],
                                 [5, 135000, 60000, "idle", 0], [6, 150000, 15000, "active", 0],
                                 [7, 155000, 5000, "active", 300], [8, 160000, 5000, "active", 0],
                                 [9, 165000, 5000, "active", 0], [10, 170000, 5000, "active", 0]],
                   "lost": []},
    },
    {
        "name": "consecutive failures back off (5 s after the second lost report)",
        "ticks": [[0, 40000]], "activity": [[0, 40000]],
        "increments": [{"from": 1000, "to": 40000, "step": 1000, "output": 100}],
        "outcomes": {"1": ["fail", "fail"], "2": ["fail", "fail"]},
        "expect": {"delivered": [[3, 21500, 5000, "active", 500], [4, 26500, 5000, "active", 500],
                                 [5, 31500, 5000, "active", 500], [6, 36500, 5000, "active", 500]],
                   "lost": [1, 2]},
    },
    {
        "name": "pause during a Retry-After wait sends no leaving report",
        "ticks": [[0, 40000]], "activity": [[0, 40000]],
        "increments": [{"from": 1000, "to": 40000, "step": 1000, "output": 100}],
        "outcomes": {"2": ["rateLimited:20"]},
        "events": [[15000, "pause"], [35000, "resume"]],
        "expect": {"delivered": [[1, 5000, 5000, "active", 500], [3, 39500, 5000, "active", 500]],
                   "lost": [2]},
    },
    {
        "name": "pause during a backoff still sends its leaving report (one attempt)",
        "ticks": [[0, 20000]], "activity": [[0, 20000]],
        "increments": [{"from": 1000, "to": 20000, "step": 1000, "output": 100}],
        "outcomes": {"1": ["fail", "fail"], "2": ["fail", "fail"]},
        "events": [[14000, "pause"]],
        "expect": {"delivered": [[3, 14000, 500, "leaving", 100]],
                   "lost": [1, 2]},
    },
]

HTTPS_DISCOVERY = "https://example.com/.well-known/agent-speed-report"
LOOPBACK_DISCOVERY = "http://127.0.0.1:8787/.well-known/agent-speed-report"


def _discovery(service=None, **changes) -> dict:
    document = {"protocol": "agent-speed-report", "versions": [1],
                "service": {"name": "Example", "terms": "https://example.com/terms",
                            "privacy": "https://example.com/privacy", **(service or {})},
                "api": "https://api.example.com/agent-speed"}
    document.update(changes)
    return document


_LINKS_DROPPED = {"homepage": None, "leaderboard": None, "apiKeyUrl": None}
DISCOVERY_CASES = [
    {"name": "a minimal document gets the defaults; apiKey.mode is none",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery(),
     "expect": {"api": "https://api.example.com/agent-speed", "apiKeyMode": "none", "apiKeyUrl": None,
                "homepage": None, "leaderboard": None, "limits": DEFAULT_LIMITS, "username": DEFAULT_USERNAME_RULES,
                "sections": list(SECTIONS)}},
    {"name": "apiKey without mode means none",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery(apiKey={"url": "https://example.com/keys"}),
     "expect": {"apiKeyMode": "none", "apiKeyUrl": "https://example.com/keys"}},
    {"name": "optional links that are not https are dropped; the document stays valid",
     "fetchedFrom": HTTPS_DISCOVERY,
     "document": _discovery({"homepage": "http://example.com/", "leaderboard": "javascript:alert(1)"},
                            apiKey={"mode": "optional", "url": "https://user@example.com/keys"}),
     "expect": {"apiKeyMode": "optional", **_LINKS_DROPPED}},
    {"name": "optional links of a loopback test server are dropped too (links are always https)",
     "fetchedFrom": LOOPBACK_DISCOVERY,
     "document": _discovery({"leaderboard": "http://127.0.0.1:8787/live"}, api="http://127.0.0.1:8787"),
     "expect": {"api": "http://127.0.0.1:8787", "leaderboard": None}},
    {"name": "an optional link of the wrong type makes the document invalid",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery({"leaderboard": 42}),
     "expect": {"invalid": "service.leaderboard"}},
    {"name": "terms that are not https make the document invalid",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery({"terms": "http://example.com/terms"}),
     "expect": {"invalid": "service.terms"}},
    {"name": "loopback http terms are invalid even from a loopback test server",
     "fetchedFrom": LOOPBACK_DISCOVERY,
     "document": _discovery({"terms": "http://127.0.0.1:8787/terms"}, api="http://127.0.0.1:8787"),
     "expect": {"invalid": "service.terms"}},
    {"name": "a missing privacy link makes the document invalid",
     "fetchedFrom": HTTPS_DISCOVERY,
     "document": {**_discovery(), "service": {"name": "Example", "terms": "https://example.com/terms"}},
     "expect": {"invalid": "service.privacy"}},
    {"name": "a loopback http api is accepted from a document fetched over loopback http",
     "fetchedFrom": LOOPBACK_DISCOVERY, "document": _discovery(api="http://localhost:8787/agent-speed/"),
     "expect": {"api": "http://localhost:8787/agent-speed"}},
    {"name": "a loopback http api in a document fetched over https is invalid",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery(api="http://127.0.0.1:8787"),
     "expect": {"invalid": "api"}},
    {"name": "an http api with any other host is invalid",
     "fetchedFrom": LOOPBACK_DISCOVERY, "document": _discovery(api="http://192.168.1.5:8787"),
     "expect": {"invalid": "api"}},
    {"name": "an api with a query is invalid",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery(api="https://api.example.com/v?x=1"),
     "expect": {"invalid": "api"}},
    {"name": "an unknown apiKey.mode is invalid",
     "fetchedFrom": HTTPS_DISCOVERY, "document": _discovery(apiKey={"mode": "sometimes"}),
     "expect": {"invalid": "apiKey.mode"}},
    {"name": "numbers outside their ranges are clamped; the heartbeat never below the interval",
     "fetchedFrom": HTTPS_DISCOVERY,
     "document": _discovery({"retentionDays": 9000},
                            limits={"intervalSeconds": 600, "heartbeatSeconds": 10, "maxAgeSeconds": 1,
                                    "maxBodyBytes": 1_000_000, "maxModels": 40},
                            username={"minLength": 0, "maxLength": 64}),
     "expect": {"retentionDays": 3650,
                "limits": {"intervalSeconds": 300, "heartbeatSeconds": 300, "maxAgeSeconds": 10,
                           "maxBodyBytes": 65_536, "maxModels": 16},
                "username": {"minLength": 1, "maxLength": 32, "charset": "unicode", "spaces": True}}},
    {"name": "unknown fields and section names are ignored (machineTraffic is no longer a section)",
     "fetchedFrom": HTTPS_DISCOVERY,
     "document": _discovery(sections=["cost", "future", "machineTraffic", "sources"], extra={"x": 1}),
     "expect": {"sections": ["sources", "cost"]}},
]


# ------------------------------------------------------------------------------------------------- checking

def _apply_change(request: dict, change: dict) -> dict:
    result = copy.deepcopy(request)
    for key, value in change.items():
        if key == "headers":
            result["headers"].update(value)
        else:
            result[key] = value
    return result


def check_vectors(vectors: dict, verbose: bool) -> list[str]:
    failures: list[str] = []
    rfc = vectors["rfc6979"]
    d = int(rfc["d"], 16)
    if public_key(d) != (int(rfc["x"], 16), int(rfc["y"], 16)):
        failures.append("rfc6979: public key mismatch")
    for item in rfc["messages"]:
        expected = bytes.fromhex(item["r"] + item["s"])
        if sign(d, item["message"].encode()) != expected:
            failures.append(f"rfc6979: signature of {item['message']!r} differs")
        if not verify(public_key(d), item["message"].encode(), expected):
            failures.append(f"rfc6979: signature of {item['message']!r} does not verify")
    keys = {}
    for name, key in vectors["keys"].items():
        d = int(key["d"], 16)
        pub = public_key(d)
        keys[name] = pub
        if key["jwk"] != jwk(pub) or key["spki"] != b64url(spki(pub)) or key["thumbprint"] != thumbprint(pub):
            failures.append(f"keys.{name}: encodings differ")
    for name, request in vectors["requests"].items():
        body = request["body"].encode("utf-8")
        headers = {k.lower(): v for k, v in request["headers"].items()}
        canonical = canonical_string(request["method"], request["authority"], request["path"],
                                     headers["x-agentspeed-timestamp"], headers["x-agentspeed-nonce"],
                                     headers["x-agentspeed-device"], body)
        if canonical != request["canonical"] or sha256_hex(body) != request["bodySha256"]:
            failures.append(f"requests.{name}: canonical string differs")
        if authority_of(request["url"]) != request["authority"] or path_of(request["url"]) != request["path"]:
            failures.append(f"requests.{name}: authority or path differs")
    for case in vectors["verify"]:
        request = _apply_change(vectors["requests"][case["request"]], case.get("change", {}))
        headers = {k.lower(): v for k, v in request["headers"].items()}
        header = case.get("header", "X-AgentSpeed-Signature").lower()
        try:
            extra_ok = SIGNATURE_RE.match(headers.get(header, "")) and len(b64url_decode(headers[header])) == 64
        except ValueError:
            extra_ok = False
        if check_signature_headers(headers) or not extra_ok:
            result = "malformed"
        else:
            ok = verify_signature(keys[case["key"]], request["method"], request["authority"], request["path"],
                                  headers, request["body"].encode("utf-8"), header)
            result = "valid" if ok else "invalid"
        if result != case["expect"]:
            failures.append(f"verify: {case['name']}: {result}, expected {case['expect']}")
    for case in vectors["publicKeys"]:
        try:
            parse_jwk(case["jwk"])
            result = "valid"
        except ValueError:
            result = "invalid"
        if result != case["expect"]:
            failures.append(f"publicKeys: {case['name']}: {result}")
    for case in vectors["server"]:
        config = case["config"]
        service = ReferenceService(authority=config["authority"], api_path=config["apiPath"],
                                   api_key_mode=config.get("apiKey", "none"), api_keys=tuple(config.get("apiKeys", ())))
        for index, step in enumerate(case["steps"]):
            request = step["request"]
            status, _, body = service.handle(request["method"], request["path"], request["headers"],
                                             request["body"].encode("utf-8"), now=step["at"])
            expect = step["expect"]
            got = {"status": status}
            if body and "error" in body:
                got["code"] = body["error"]["code"]
                if "reason" in expect:
                    got["reason"] = body["error"].get("reason")
                if "username" in expect:
                    got["username"] = body["error"].get("username")
                if "field" in expect:
                    got["field"] = body["error"].get("field")
            elif body:
                got["result"] = body.get("status")
                if "transferred" in expect:
                    got["transferred"] = body.get("transferred")
            if got != expect:
                failures.append(f"server: {case['name']} step {index + 1}: {got}, expected {expect}")
    usernames = vectors["usernames"]
    for case in usernames["validate"]:
        rules = username_rules(usernames["rules"][case["rules"]])
        if validate_username(case["name"], rules) != case["expect"]:
            failures.append(f"usernames.validate {case['name']!r}: {validate_username(case['name'], rules)}")
    for case in usernames["fit"]:
        rules = username_rules(usernames["rules"][case["rules"]])
        if fit_username(case["computerName"], rules) != case["expect"]:
            failures.append(f"usernames.fit {case['computerName']!r}: {fit_username(case['computerName'], rules)!r}")
    for case in usernames["keys"]:
        if (username_key(case["a"]) == username_key(case["b"])) != case["same"]:
            failures.append(f"usernames.keys {case['a']!r} / {case['b']!r}")
    for case in vectors["scheduler"]:
        result = simulate_scheduler(case)
        if result != case["expect"]:
            failures.append(f"scheduler: {case['name']}: got {json.dumps(result)}")
        elif verbose:
            print(f"  scheduler ok: {case['name']}")
    for case in vectors["discovery"]:
        try:
            parsed = parse_discovery(case["document"], case["fetchedFrom"])
            got = {key: parsed.get(key) for key in case["expect"]}
        except DiscoveryError as error:
            got = {"invalid": str(error)}
        if got != case["expect"]:
            failures.append(f"discovery: {case['name']}: got {json.dumps(got)}")
    return failures


def _discovery_problems(document: dict, fetched_from: str) -> list[str]:
    try:
        parse_discovery(document, fetched_from)
        return []
    except DiscoveryError as error:
        return [f"a client rejects it at {error}"]


def check_examples(verbose: bool) -> list[str]:
    schema = load_schema()
    failures = []
    for name, document in load_examples().items():
        if name.startswith("report-"):
            errors = report_errors(document, schema)
        elif name in ("discovery", "registration"):
            errors = schema_errors(document, schema["$defs"][name], schema, closed=True)
            if name == "discovery":
                errors += _discovery_problems(document, HTTPS_DISCOVERY)
        elif name == "responses":
            errors = []
            for index, item in enumerate(document["responses"]):
                definition = "error" if "error" in item["body"] else "success"
                errors += schema_errors(item["body"], schema["$defs"][definition], schema,
                                        f"$.responses[{index}]", closed=True)
        else:
            errors = [f"unexpected example {name}"]
        failures += [f"examples/{name}.json: {error}" for error in errors]
        if verbose and not errors:
            print(f"  example ok: {name}")
    for scheme, fetched_from in (("https", HTTPS_DISCOVERY), ("http", LOOPBACK_DISCOVERY)):
        document = ReferenceService(authority=authority_of(fetched_from)).discovery(scheme)
        problems = schema_errors(document, schema["$defs"]["discovery"], schema, closed=True)
        problems += _discovery_problems(document, fetched_from)
        failures += [f"reference server discovery ({scheme}): {problem}" for problem in problems]
    return failures


def cross_check(vectors: dict) -> str:
    """Optional: verify every vector signature with the cryptography package when it is installed."""
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
    except ImportError:
        return "cryptography not installed: cross-check skipped"
    count = 0
    for request in vectors["requests"].values():
        key = request["headers"]["X-AgentSpeed-Signature"]
        raw = b64url_decode(key)
        pub_jwk = vectors["keys"]["device"]["jwk"]
        numbers = ec.EllipticCurvePublicNumbers(int.from_bytes(b64url_decode(pub_jwk["x"]), "big"),
                                                int.from_bytes(b64url_decode(pub_jwk["y"]), "big"), ec.SECP256R1())
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        try:
            numbers.public_key().verify(der, request["canonical"].encode("utf-8"), ec.ECDSA(hashes.SHA256()))
        except InvalidSignature:
            raise SystemExit(f"cryptography rejects the signature of {request['url']}")
        count += 1
    private = ec.derive_private_key(int(vectors["keys"]["device"]["d"], 16), ec.SECP256R1())
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    message = vectors["requests"]["report"]["canonical"].encode("utf-8")
    r, s = decode_dss_signature(private.sign(message, ec.ECDSA(hashes.SHA256())))
    if not verify(public_key(int(vectors["keys"]["device"]["d"], 16)), message,
                  r.to_bytes(32, "big") + s.to_bytes(32, "big")):
        raise SystemExit("the reference rejects a signature made by cryptography")
    return f"cryptography {__import__('cryptography').__version__}: {count} signatures verified both ways"


# ------------------------------------------------------------------------------------------------- client

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _http(method: str, url: str, headers: dict, body: bytes | None, cap: int = 16_384):
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.ProxyHandler())
    request = urllib.request.Request(url, data=body if body else None, method=method, headers=headers)
    try:
        with opener.open(request, timeout=10) as response:
            status, data, reply_headers = response.status, response.read(cap + 1), dict(response.headers)
    except urllib.error.HTTPError as error:
        status, data, reply_headers = error.code, error.read(cap + 1), dict(error.headers)
    if len(data) > cap:
        raise SystemExit(f"{method} {url}: response larger than {cap} bytes")
    try:
        payload = json.loads(data.decode("utf-8")) if data else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = {"_raw": data[:200].decode("utf-8", "replace")}
    return status, reply_headers, payload


def run_client(args) -> int:
    service = args.url.rstrip("/")
    if not (service.startswith("https://") or re.match(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$", service)):
        raise SystemExit("the service URL must be https:// (http only for loopback test servers)")
    status, _, discovery = _http("GET", f"{service}/.well-known/agent-speed-report", {
        "Accept": "application/json", "User-Agent": "AgentSpeed/0.0.0 (macOS)"}, None, 65_536)
    if status != 200:
        raise SystemExit(f"discovery failed: HTTP {status}")
    try:
        discovery = parse_discovery(discovery, f"{service}/.well-known/agent-speed-report")
    except DiscoveryError as error:
        raise SystemExit(f"discovery failed: invalid {error}")
    if 1 not in discovery["versions"]:
        raise SystemExit(f"the service accepts only protocol versions {discovery['versions']}")
    print(f"service: {discovery['name']}  api: {discovery['api']}  versions: {discovery['versions']}  "
          f"api key: {discovery['apiKeyMode']}")
    api = discovery["api"]
    limits = discovery["limits"]
    rules = discovery["username"]
    username = unicodedata.normalize("NFKC", args.username or random_username())
    reason = validate_username(username, rules)
    if reason:
        raise SystemExit(f"username {username!r} is invalid for this service: {reason}")
    if args.key_file and Path(args.key_file).exists():
        saved = json.loads(Path(args.key_file).read_text())
        d, device_id = int(saved["d"], 16), saved["deviceId"]
    else:
        d, device_id = secrets.randbelow(N - 1) + 1, str(uuid.uuid4())
        if args.key_file:
            Path(args.key_file).write_text(json.dumps({"d": f"{d:064x}", "deviceId": device_id}))
    pub = public_key(d)
    print(f"device {device_id}  key thumbprint {thumbprint(pub)}")

    def call(method, path, document=None, **extra):
        body = compact_json(document) if document is not None else b""
        url = f"{api}{path}"
        headers = signed_headers(d, method, url, device_id, body, api_key=args.api_key, **extra)
        status, reply_headers, payload = _http(method, url, headers, body)
        print(f"{method} {path} -> {status} {json.dumps(payload, ensure_ascii=False)}")
        return status, reply_headers, payload

    status, _, payload = call("POST", "/v1/devices", json.loads(_registration(device_id, username, pub)))
    if status not in (200, 201):
        return 1
    username = payload.get("username", username)
    run_id = str(uuid.uuid4())
    template = load_examples()["report-active"]
    accepted = set(discovery["sections"]) & set(DEFAULT_SECTIONS)
    for seq in range(1, args.reports + 1):
        report = copy.deepcopy(template)
        for section in SECTIONS:
            if section not in accepted:
                report.pop(section, None)
        report.update(deviceId=device_id, username=username, run={"id": run_id, "seq": seq},
                      sentAt=format_instant(int(time.time() * 1000)))
        report["activity"] = "leaving" if seq == args.reports and args.leave else "active"
        status, headers, payload = call("POST", "/v1/reports", report)
        if status == 429:
            time.sleep(min(60, int(headers.get("Retry-After", "5"))))
        elif seq < args.reports and not args.fast:
            time.sleep(limits["intervalSeconds"])
    if args.rename:
        call("PATCH", f"/v1/devices/{device_id}", {"username": unicodedata.normalize("NFKC", args.rename)})
    if args.rotate:
        new_d = secrets.randbelow(N - 1) + 1
        status, _, _ = call("PUT", f"/v1/devices/{device_id}/key", {"publicKey": jwk(public_key(new_d))},
                            new_key=new_d)
        if status == 200:
            d = new_d
            if args.key_file:
                Path(args.key_file).write_text(json.dumps({"d": f"{d:064x}", "deviceId": device_id}))
    if args.forget:
        status, _, _ = call("DELETE", f"/v1/devices/{device_id}")
        if status in (200, 404) and args.key_file:
            Path(args.key_file).unlink(missing_ok=True)
    return 0


# ------------------------------------------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--write", action="store_true", help="regenerate spec/fixtures/report-vectors.json")
    parser.add_argument("--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command")
    client = sub.add_parser("client", help="register and send example reports to a server")
    client.add_argument("--url", required=True, help="service URL, e.g. http://127.0.0.1:8787")
    client.add_argument("--username", help="default: a random racer-xxxxxx name")
    client.add_argument("--api-key")
    client.add_argument("--reports", type=int, default=3)
    client.add_argument("--fast", action="store_true", help="do not wait intervalSeconds between reports")
    client.add_argument("--leave", action="store_true", help="mark the last report as leaving")
    client.add_argument("--rename", help="rename the device after reporting")
    client.add_argument("--rotate", action="store_true", help="rotate the device key after reporting")
    client.add_argument("--forget", action="store_true", help="delete the device at the end")
    client.add_argument("--key-file", help="keep the test device key in this JSON file between runs")
    args = parser.parse_args()
    if args.command == "client":
        return run_client(args)
    if args.write:
        vectors = build_vectors()
        VECTORS_PATH.write_text(json.dumps(vectors, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"wrote {VECTORS_PATH.relative_to(SPEC.parent)}")
    vectors = json.loads(VECTORS_PATH.read_text(encoding="utf-8"))
    failures = check_examples(args.verbose) + check_vectors(vectors, args.verbose)
    if not args.write and json.dumps(build_vectors(), ensure_ascii=False, sort_keys=True) != \
            json.dumps(vectors, ensure_ascii=False, sort_keys=True):
        failures.append("report-vectors.json is not what --write produces (run with --write after a spec change)")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    counts = (len(vectors["verify"]), len(vectors["server"]), len(vectors["scheduler"]), len(vectors["discovery"]))
    print(f"{'FAILED' if failures else 'ok'}: {len(failures)} failures; {counts[0]} signature cases, "
          f"{counts[1]} server cases, {counts[2]} scheduler cases, {counts[3]} discovery cases; "
          f"{cross_check(vectors)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
