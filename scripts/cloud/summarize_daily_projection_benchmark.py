"""Validate paired hosted evidence and report medians without a timing SLA."""
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
baseline, candidate = sys.argv[2:4]
records = []
for source in (baseline, candidate):
    for size in (3650, 36500):
        for trial in (1, 2, 3):
            log = root / f"{source}-{size}-{trial}.log"
            rows = [json.loads(line.split("DAILY_PROJECTION_BENCHMARK ", 1)[1])
                    for line in log.read_text().splitlines()
                    if "DAILY_PROJECTION_BENCHMARK " in line]
            assert {row["phase"] for row in rows} == {"first", "unchanged", "incremental"}
            assert len(rows) == 3
            for row in rows:
                assert (row["source"], row["fixtureRows"], row["trial"]) == (source, size, trial)
                assert row["requests"] == size and row["resultRows"] == 365
                assert row["tokens"] == size * 1100 + (100 if row["phase"] == "incremental" else 0)
                assert row["processPeakBytesAfter"] >= row["processPeakBytesBefore"] > 0
                assert row["milliseconds"] >= 0
            records.extend(rows)

summary = []
for source in (baseline, candidate):
    for size in (3650, 36500):
        for phase in ("first", "unchanged", "incremental"):
            rows = [row for row in records if (row["source"], row["fixtureRows"], row["phase"]) == (source, size, phase)]
            summary.append({
                "source": source, "fixtureRows": size, "phase": phase, "trials": len(rows),
                "medianMilliseconds": statistics.median(row["milliseconds"] for row in rows),
                "maxProcessPeakBytes": max(row["processPeakBytesAfter"] for row in rows),
                "maxProcessPeakGrowthBytes": max(row["processPeakGrowthBytes"] for row in rows),
            })
result = {
    "baseline": baseline, "candidate": candidate, "records": records, "summary": summary,
    "memoryMeaning": "Darwin process high-water RSS including XCTest and fixture setup; growth is not isolated query allocation.",
    "comparisonMeaning": "Identical synthetic rows and token/call checks; the candidate additionally prices requests and retains model details.",
}
(root / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(summary, indent=2))
