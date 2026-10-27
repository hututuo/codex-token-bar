"""In-memory profile, avatar, pairing and shared-user reference state. Not production storage."""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import struct
import uuid
import zlib
from collections import defaultdict, deque

from execution_modes_reference import FIELDS, supported

PAIR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
PAIR_PATH = re.compile(r"^/v1/profile/pairings/([0-9a-f-]{36})(/approve)?$")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
AVATAR_LIMIT = 512 * 1024


def sanitize_avatar(body):
    if not isinstance(body, bytes) or len(body) > AVATAR_LIMIT or not body.startswith(PNG_MAGIC):
        raise ValueError("avatar_invalid")
    offset, header, compressed, ended = 8, None, bytearray(), False
    while offset < len(body):
        if offset + 12 > len(body):
            raise ValueError("avatar_invalid")
        size = struct.unpack(">I", body[offset:offset + 4])[0]
        tag = body[offset + 4:offset + 8]
        end = offset + 12 + size
        if end > len(body):
            raise ValueError("avatar_invalid")
        payload = body[offset + 8:offset + 8 + size]
        crc = struct.unpack(">I", body[offset + 8 + size:end])[0]
        if crc != zlib.crc32(tag + payload) & 0xffffffff:
            raise ValueError("avatar_invalid")
        if tag == b"IHDR":
            if header is not None or offset != 8 or size != 13:
                raise ValueError("avatar_invalid")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if (width, height, depth, compression, filtering, interlace) != (256, 256, 8, 0, 0, 0) or color not in (2, 6):
                raise ValueError("avatar_invalid")
            header = payload
        elif tag == b"IDAT":
            if header is None:
                raise ValueError("avatar_invalid")
            compressed.extend(payload)
        elif tag == b"IEND":
            if size or end != len(body):
                raise ValueError("avatar_invalid")
            ended = True
        elif tag in (b"acTL", b"fcTL", b"fdAT") or (tag and not tag[0] & 32):
            raise ValueError("avatar_invalid")
        offset = end
    if not ended or header is None or not compressed:
        raise ValueError("avatar_invalid")
    channels = 4 if header[9] == 6 else 3
    stride = 1 + 256 * channels
    expected = 256 * stride
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise ValueError("avatar_invalid") from error
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("avatar_invalid")
    if any(pixels[index] > 4 for index in range(0, expected, stride)):
        raise ValueError("avatar_invalid")
    def chunk(tag, value):
        return struct.pack(">I", len(value)) + tag + value + struct.pack(">I", zlib.crc32(tag + value) & 0xffffffff)
    return PNG_MAGIC + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class ProfileExtensions:
    def __init__(self, service, api):
        self.service, self.api = service, api
        self.users, self.bindings, self.pairings, self.avatars = {}, {}, {}, {}
        self.contributions = {}
        self.secret = secrets.token_bytes(32)
        self.limits = defaultdict(deque)

    def allowed(self, route):
        caps = self.service.extensions
        if route == "/v1/profile" and any(supported(caps, k) for k in ("profileAvatar", "sharedIdentity")):
            return ("GET", "PATCH") if supported(caps, "sharedIdentity") else ("GET",)
        if route == "/v1/profile/avatar" and supported(caps, "profileAvatar"):
            return ("GET", "PUT", "DELETE")
        if not supported(caps, "sharedIdentity"):
            return None
        if route == "/v1/profile/identity":
            return ("POST", "DELETE")
        if route in ("/v1/profile/pairings", "/v1/profile/pairings/claim"):
            return ("POST",)
        match = PAIR_PATH.fullmatch(route)
        if match and self.api.UUID_RE.fullmatch(match[1]):
            return ("POST",) if match[2] else ("GET", "DELETE")
        return None

    def _limited(self, key, now, count=5, window=60):
        history = self.limits[key]
        while history and history[0] <= now - window:
            history.popleft()
        if len(history) >= count:
            return True
        history.append(now)
        return False

    def _owner(self, device_id):
        return ("user", self.bindings[device_id]) if device_id in self.bindings else ("device", device_id)

    def _avatar(self, owner):
        blob = self.avatars.get(owner)
        if blob is None:
            return None
        digest = hashlib.sha256(blob).hexdigest()
        return {"url": f"https://{self.service.authority}{self.service.api_path}/public/avatars/{digest}.png",
                "sha256": digest, "contentType": "image/png", "width": 256, "height": 256}

    def public_avatar(self, path):
        if not supported(self.service.extensions, "profileAvatar"):
            return None
        prefix = self.service.api_path + "/public/avatars/"
        if not path.startswith(prefix) or not re.fullmatch(r"[0-9a-f]{64}\.png", path[len(prefix):]):
            return None
        digest = path[len(prefix):-4]
        blob = next((value for value in self.avatars.values() if hashlib.sha256(value).hexdigest() == digest), None)
        if blob is None:
            return self.service._error(404, "avatar_not_set")
        return 200, {"Content-Type": "image/png", "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"}, blob

    def public_id(self, owner):
        return hmac.new(self.secret, (owner[0] + ":" + owner[1]).encode("ascii"), hashlib.sha256).hexdigest()

    def profile(self, device_id, now):
        owner = self._owner(device_id)
        user_id = self.bindings.get(device_id)
        peers = sorted(d for d in self.service.devices if self.bindings.get(d) == user_id) if user_id else [device_id]
        online = {id(d) for d in self.service.online(now)}
        return {"sharedUserId": user_id,
                "displayName": self.users[user_id]["displayName"] if user_id else self.service.devices[device_id]["username"],
                "avatar": self._avatar(owner),
                "devices": [{"deviceId": peer, "platform": self.service.devices[peer]["client"]["platform"],
                             "isCurrent": peer == device_id, "online": id(self.service.devices[peer]) in online}
                            for peer in peers]}

    def _clear_live(self, device_id):
        self.service.devices[device_id]["online"] = False

    def _pair_view(self, pair, now):
        state = pair["state"]
        if state in ("waiting", "pending") and pair["expires"] <= now:
            state = "expired"
        result = {"id": pair["id"], "state": state, "expiresAt": self.api.format_instant(int(pair["expires"] * 1000))}
        claimant = pair.get("claimant")
        if claimant and claimant in self.service.devices:
            result["claimant"] = {"deviceId": claimant, "platform": self.service.devices[claimant]["client"]["platform"]}
        return result

    def _code_hash(self, value):
        return hmac.new(self.secret, value.encode("ascii"), hashlib.sha256).digest()

    def handle(self, device_id, method, route, headers, body, document, now):
        error = self.service._error
        owner = self._owner(device_id)
        permitted = {"displayName"} if route == "/v1/profile" and method == "PATCH" else (
            {"code"} if route == "/v1/profile/pairings/claim" else set())
        if document is not None and not set(document).issubset(permitted):
            return error(422, "payload_invalid", field="/")
        if route == "/v1/profile":
            if method == "PATCH":
                if device_id not in self.bindings:
                    return error(409, "identity_required")
                name = (document or {}).get("displayName")
                problem = self.service._username_problem(name)
                if problem:
                    return problem
                if self._limited((owner, "rename"), now):
                    return error(429, "rate_limited", retryAfterSeconds=60)
                self.users[self.bindings[device_id]]["displayName"] = name
            return 200, {}, self.profile(device_id, now)
        if route == "/v1/profile/avatar":
            if method == "GET":
                blob = self.avatars.get(owner)
                return ((200, {"Content-Type": "image/png", "X-Content-Type-Options": "nosniff"}, blob)
                        if blob else error(404, "avatar_not_set"))
            if self._limited((device_id, "avatar"), now) or self._limited((owner, "avatar-hour"), now, 30, 3600):
                return error(429, "rate_limited", retryAfterSeconds=60)
            if method == "DELETE":
                self.avatars.pop(owner, None)
            else:
                if headers.get("content-type", "").split(";")[0].lower() != "image/png":
                    return error(422, "avatar_invalid")
                try:
                    self.avatars[owner] = sanitize_avatar(body)
                except ValueError:
                    return error(422, "avatar_invalid")
            return 200, {}, self.profile(device_id, now)
        if route == "/v1/profile/identity":
            if method == "POST" and device_id not in self.bindings:
                user_id = str(uuid.uuid4())
                self.users[user_id] = {"displayName": self.service.devices[device_id]["username"], "created": now}
                self.bindings[device_id] = user_id
                if ("device", device_id) in self.avatars:
                    self.avatars[("user", user_id)] = self.avatars[("device", device_id)]
                self._clear_live(device_id)
                return 201, {}, self.profile(device_id, now)
            if method == "DELETE":
                self.bindings.pop(device_id, None)
                self._clear_live(device_id)
                for pair in self.pairings.values():
                    if pair["creator"] == device_id and pair["state"] in ("waiting", "pending"):
                        pair["state"] = "cancelled"
            return 200, {}, self.profile(device_id, now)
        if route == "/v1/profile/pairings":
            user_id = self.bindings.get(device_id)
            if user_id is None:
                return error(409, "identity_required")
            if self._limited((device_id, "invite"), now):
                return error(429, "rate_limited", retryAfterSeconds=60)
            for pair in self.pairings.values():
                if pair["creator"] != device_id or pair["expires"] <= now:
                    continue
                if pair["state"] == "pending":
                    return error(409, "pairing_pending")
                if pair["state"] == "waiting":
                    pair["state"] = "cancelled"
            code = "".join(secrets.choice(PAIR_ALPHABET) for _ in range(12))
            pair_id = str(uuid.uuid4())
            pair = {"id": pair_id, "creator": device_id, "user": user_id, "state": "waiting",
                    "hash": self._code_hash(code), "expires": now + 600}
            self.pairings[pair_id] = pair
            result = self._pair_view(pair, now)
            result["code"] = "-".join(code[i:i + 4] for i in range(0, 12, 4))
            return 201, {}, result
        if route == "/v1/profile/pairings/claim":
            if self._limited((device_id, "claim"), now):
                return error(429, "rate_limited", retryAfterSeconds=60)
            code = (document or {}).get("code")
            normalized = code.replace("-", "").upper() if isinstance(code, str) and len(code) <= 32 else ""
            if len(normalized) != 12 or any(c not in PAIR_ALPHABET for c in normalized):
                return error(422, "pairing_invalid")
            digest = self._code_hash(normalized)
            approved = next((p for p in self.pairings.values() if hmac.compare_digest(p["hash"], digest)
                             and p["state"] == "approved" and p.get("claimant") == device_id
                             and self.bindings.get(device_id) == p["user"]), None)
            if approved:
                return 202, {}, self._pair_view(approved, now)
            if device_id in self.bindings:
                return error(409, "already_bound")
            pair = next((p for p in self.pairings.values() if hmac.compare_digest(p["hash"], digest)
                         and p["state"] in ("waiting", "pending") and p["expires"] > now), None)
            if pair is None:
                return error(422, "pairing_invalid")
            if pair.get("claimant") not in (None, device_id):
                return error(409, "pairing_pending")
            pair.update(claimant=device_id, state="pending")
            return 202, {}, self._pair_view(pair, now)
        match = PAIR_PATH.fullmatch(route)
        pair = self.pairings.get(match[1]) if match else None
        if pair is None or device_id not in (pair["creator"], pair.get("claimant")):
            return error(404, "not_found")
        if method == "GET":
            return 200, {}, self._pair_view(pair, now)
        if method == "DELETE":
            if pair["state"] != "approved":
                pair["state"] = "cancelled"
            return 204, {}, None
        if device_id != pair["creator"]:
            return error(404, "not_found")
        if pair["state"] == "approved":
            return 200, {}, self._pair_view(pair, now)
        if pair["expires"] <= now:
            return error(410, "pairing_expired")
        claimant = pair.get("claimant")
        if (pair["state"] != "pending" or claimant not in self.service.devices
                or self.bindings.get(device_id) != pair["user"]):
            return error(409, "pairing_invalid")
        if claimant in self.bindings:
            return error(409, "already_bound")
        if sum(user == pair["user"] for user in self.bindings.values()) >= 32:
            return error(409, "device_limit")
        self.bindings[claimant] = pair["user"]
        self._clear_live(claimant)
        pair["state"] = "approved"
        return 200, {}, self._pair_view(pair, now)

    def record_report(self, device_id, document, now):
        owner = self._owner(device_id)
        self.service.devices[device_id]["lastOwner"] = owner
        bucket = self.contributions.setdefault((device_id, owner), {"totals": defaultdict(int), "models": {}})
        for field, value in document["delta"].items():
            bucket["totals"][field] += value
        bucket["totals"]["costMicroUsd"] += document.get("cost", {}).get("deltaMicroUsd", 0)
        for model in document.get("models", []):
            target = bucket["models"].setdefault(model["id"], {"totals": defaultdict(int), "harness": defaultdict(int),
                                                             "modes": {}, "windows": {}, "coverage": {}})
            for field in FIELDS:
                target["totals"][field] += model[field]
            rows = model.get("harnessRequests") if supported(self.service.extensions, "modelHarnessRequests") else None
            if rows is not None:
                for row in rows:
                    target["harness"][(row["source"],)] += row["requests"]
            else:
                target["harness"][tuple(model["sources"])] += model["requests"]
            if supported(self.service.extensions, "executionModes"):
                sources = tuple(model["sources"])
                window = target["windows"].setdefault(sources, defaultdict(int))
                for field in FIELDS:
                    window[field] += model[field]
                kinds = set()
                for row in model.get("modeUsage", []):
                    kinds.add(row["kind"])
                    key = tuple(row.get(field, "") for field in ("source", "provider", "kind", "mode", "evidence"))
                    values = target["modes"].setdefault(key, defaultdict(int))
                    for field in FIELDS:
                        values[field] += row[field]
                for kind in kinds:
                    covered = target["coverage"].setdefault((sources, kind), defaultdict(int))
                    for field in FIELDS:
                        covered[field] += model[field]

    def delete_device(self, device_id):
        self.bindings.pop(device_id, None)
        self.avatars.pop(("device", device_id), None)
        self.contributions = {key: value for key, value in self.contributions.items() if key[0] != device_id}
        for pair in self.pairings.values():
            if device_id in (pair["creator"], pair.get("claimant")) and pair["state"] in ("waiting", "pending"):
                pair["state"] = "cancelled"

    def public_users(self, now):
        rows = {}
        def ensure(owner):
            if owner not in rows:
                kind, identity = owner
                name = (self.users.get(identity, {}).get("displayName") if kind == "user"
                        else self.service.devices.get(identity, {}).get("username"))
                if name is None:
                    return None
                rows[owner] = {"id": self.public_id(owner), "displayName": name, "avatar": self._avatar(owner),
                               "onlineDevices": 0, "live": {"outputTokS": 0, "totalTokS": 0, "generating": 0, "tools": 0},
                               "totals": defaultdict(int), "models": {}}
            return rows[owner]
        for (_, owner), bucket in self.contributions.items():
            target = ensure(owner)
            if target is None:
                continue
            for field, value in bucket["totals"].items():
                target["totals"][field] += value
            for model_id, model in bucket["models"].items():
                merged = target["models"].setdefault(model_id, {"id": model_id, "totals": defaultdict(int),
                                                               "harness": defaultdict(int), "modes": {},
                                                               "windows": {}, "coverage": {}})
                for field, value in model["totals"].items():
                    merged["totals"][field] += value
                for key, value in model["harness"].items():
                    merged["harness"][key] += value
                for collection in ("modes", "windows", "coverage"):
                    for key, values in model[collection].items():
                        group = merged[collection].setdefault(key, defaultdict(int))
                        for field, value in values.items():
                            group[field] += value
        online = {id(d) for d in self.service.online(now)}
        for device_id, device in self.service.devices.items():
            owner = self._owner(device_id)
            if id(device) not in online or device.get("lastOwner") != owner:
                continue
            target = ensure(owner)
            if target is None:
                continue
            target["onlineDevices"] += 1
            live = device["last"]["live"]
            target["live"]["outputTokS"] += live["outputTokS"]
            target["live"]["totalTokS"] += live["totalTokS"]
            for field in ("generating", "tools"):
                target["live"][field] += live["agents"][field]
        for row in rows.values():
            row["totals"] = dict(row["totals"])
            models = []
            for model in row["models"].values():
                model["harnessRequests"] = [{"sources": list(key), "requests": value}
                                            for key, value in sorted(model.pop("harness").items())]
                groups = {((key[0],), *key[1:]): dict(value) for key, value in model.pop("modes").items()}
                windows, coverage = model.pop("windows"), model.pop("coverage")
                kinds = {key[2] for key in groups} | {"serviceTier"}
                if supported(self.service.extensions, "executionModes"):
                    for sources, values in windows.items():
                        for kind in kinds:
                            covered = coverage.get((sources, kind), {})
                            missing = {field: values[field] - covered.get(field, 0) for field in FIELDS}
                            if any(missing.values()):
                                key = (sources, "", kind, "unknown", "unknown")
                                group = groups.setdefault(key, {field: 0 for field in FIELDS})
                                for field in FIELDS:
                                    group[field] += missing[field]
                    model["modeUsage"] = [
                        {**({"source": key[0][0]} if len(key[0]) == 1 else {"sources": list(key[0])}),
                         **({"provider": key[1]} if key[1] else {}),
                         **dict(zip(("kind", "mode", "evidence"), key[2:])), **value}
                        for key, value in sorted(groups.items())]
                model.update(dict(model.pop("totals")))
                models.append(model)
            row["models"] = sorted(models, key=lambda m: m["id"])
        return sorted(rows.values(), key=lambda row: (-row["live"]["outputTokS"], row["id"]))
