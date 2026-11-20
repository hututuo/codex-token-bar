#!/usr/bin/env python3
"""Build the deterministic, read-only o200k rank lookup shipped with the app."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct

SOURCE_SHA256 = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"
MAGIC = b"CTBO2K01"
SLOTS = 1 << 19
TOKEN_COUNT = 199_998
HEADER_BYTES = 64


def token_hash(token):
    value = 2_166_136_261
    for byte in token:
        value = ((value ^ byte) * 16_777_619) & 0xFFFFFFFF
    return value


def compile_vocabulary(source):
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("Source vocabulary does not match the reviewed o200k vocabulary")
    table = [0] * SLOTS
    payload = bytearray()
    tokens = []
    ranks = set()
    for line in source.splitlines():
        encoded, rank_text = line.split()
        token = base64.b64decode(encoded, validate=True)
        rank = int(rank_text)
        if not token or rank in ranks or not 0 <= rank < TOKEN_COUNT:
            raise ValueError("Invalid vocabulary record")
        ranks.add(rank)
        slot = token_hash(token) & (SLOTS - 1)
        while table[slot]:
            slot = (slot + 1) & (SLOTS - 1)
        table[slot] = len(payload) + 1
        payload.extend(struct.pack("<II", rank, len(token)))
        payload.extend(token)
        tokens.append((token, rank))
    if len(tokens) != TOKEN_COUNT:
        raise ValueError("Incomplete vocabulary")
    payload_offset = HEADER_BYTES + SLOTS * 4
    header = struct.pack("<8sIIQ32s8x", MAGIC, SLOTS, TOKEN_COUNT, payload_offset,
                         bytes.fromhex(SOURCE_SHA256))
    compiled = header + struct.pack(f"<{SLOTS}I", *table) + payload
    # Independently traverse the serialized lookup for every original token.
    for token, expected in tokens:
        slot = token_hash(token) & (SLOTS - 1)
        for _ in range(SLOTS):
            offset = struct.unpack_from("<I", compiled, HEADER_BYTES + slot * 4)[0]
            if not offset:
                raise ValueError("Compiled lookup lost a token")
            position = payload_offset + offset - 1
            rank, length = struct.unpack_from("<II", compiled, position)
            if compiled[position + 8:position + 8 + length] == token:
                if rank != expected:
                    raise ValueError("Compiled lookup changed a rank")
                break
            slot = (slot + 1) & (SLOTS - 1)
        else:
            raise ValueError("Compiled lookup has no empty slot")
    return compiled


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    compiled = compile_vocabulary(args.source.read_bytes())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(compiled)
    metadata = {
        "format": MAGIC.decode(), "source_sha256": SOURCE_SHA256,
        "compiled_sha256": hashlib.sha256(compiled).hexdigest(),
        "compiled_bytes": len(compiled), "token_count": TOKEN_COUNT, "slots": SLOTS,
    }
    args.output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
