#!/usr/bin/env python3
"""Compares `--dump-today` outputs from different implementations response by response.

  python3 spec/tools/compare_dumps.py reference.jsonl swift.jsonl csharp.jsonl

Responses that end within --grace-ms of the newest dump's capture time are ignored, because the dumps are taken
seconds apart while agents keep writing.
"""
import argparse
import json
import sys

FIELDS = ("source", "agentId", "model", "startMs", "endMs", "input", "cachedInput", "cacheWriteInput", "output",
          "reasoning", "final")
# Added with the cost feature (METRICS 3.2, 9): compared whenever the other dump has them.
NEW_FIELDS = ("cacheWrite1hInput", "provider", "fast", "costMicroUsd", "requestCount")


def load(path):
    rows, summary = {}, None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if "summary" in obj:
                summary = obj["summary"]
            else:
                rows[obj["key"]] = obj
    return rows, summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dumps", nargs="+")
    parser.add_argument("--grace-ms", type=int, default=120_000)
    args = parser.parse_args()
    loaded = [(p, *load(p)) for p in args.dumps]
    newest = max((max((r["endMs"] for r in rows.values()), default=0) for _, rows, _ in loaded))
    cutoff = newest - args.grace_ms
    base_path, base, _ = loaded[0]
    failures = 0
    for path, rows, summary in loaded:
        print("%-60s responses=%d summary=%s" % (path[-60:], len(rows), json.dumps(summary)[:160]))
    for path, rows, _ in loaded[1:]:
        missing = [k for k, r in base.items() if k not in rows and r["endMs"] < cutoff]
        extra = [k for k, r in rows.items() if k not in base and r["endMs"] < cutoff]
        diffs = []
        for key, ref in base.items():
            other = rows.get(key)
            if other is None or ref["endMs"] >= cutoff:
                continue
            for field in FIELDS + tuple(f for f in NEW_FIELDS if f in other):
                if ref.get(field) != other.get(field):
                    diffs.append((key, field, ref.get(field), other.get(field)))
        failures += len(missing) + len(extra) + len(diffs)
        print("\n%s vs %s: missing=%d extra=%d field differences=%d" % (base_path, path, len(missing), len(extra),
                                                                         len(diffs)))
        for key in missing[:10]:
            print("  missing", key)
        for key in extra[:10]:
            print("  extra  ", key)
        for diff in diffs[:20]:
            print("  diff   %s %s: %r != %r" % diff)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
