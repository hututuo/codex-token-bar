import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import {
  calculateCacheRetention,
  formatRetentionCoverage,
  formatRetentionMinutes,
  formatRetentionRecommendation,
  formatRetentionRisk,
} from "./analysis.ts";

const minute = 60_000_000;

function makePoint(index, gap, cached, { input = 1_000, model = "synthetic-A" } = {}) {
  return {
    id: String(index),
    sourceKey: "source",
    sessionKey: "session",
    model,
    gapMicroseconds: gap,
    startedAtMicroseconds: 0,
    previousInput: 1_000,
    previousCached: 900,
    input,
    cached,
  };
}

function syntheticPoints() {
  return Array.from({ length: 160 }, (_, offset) => {
    const index = offset + 1;
    const percent = index <= 120 ? 80 + (index * 7 % 20) : 5 + (index * 11 % 65);
    return makePoint(
      `synthetic-${index}`,
      index * minute,
      percent * 10,
      { model: index % 2 === 0 ? "synthetic-B" : "synthetic-A" },
    );
  });
}

test("published synthetic vector matches the Swift analysis and model scopes", () => {
  const points = syntheticPoints();
  const all = calculateCacheRetention(points);
  assert.equal(all.count, 160);
  assert.equal(all.highCount, 120);
  assert.equal(all.p95Microseconds, 114 * minute);
  assert.equal(all.p95CoverageCount, 114);
  assert.equal(all.p95State, "ready");
  assert.equal(all.dropMicroseconds, 120.5 * minute);
  assert.equal(all.dropLeftMicroseconds, 120 * minute);
  assert.equal(all.dropRightMicroseconds, 121 * minute);
  assert.equal(all.dropState, "ready");
  assert.equal(all.bestSegments, 2);
  assert.deepEqual(all.segments.map(({ count }) => count), [120, 40]);
  assert.deepEqual(all.segments.map(({ highCount }) => highCount), [120, 0]);
  assert.equal(all.searchMode, "exact");

  const modelA = calculateCacheRetention(points.filter(({ model }) => model === "synthetic-A"));
  assert.equal(modelA.p95Microseconds, 113 * minute);
  assert.equal(modelA.p95State, "small_sample");
  assert.equal(modelA.dropLeftMicroseconds, 119 * minute);
  assert.equal(modelA.dropRightMicroseconds, 121 * minute);
  assert.equal(modelA.dropMicroseconds, 120 * minute);

  const modelB = calculateCacheRetention(points.filter(({ model }) => model === "synthetic-B"));
  assert.equal(modelB.p95Microseconds, 114 * minute);
  assert.equal(modelB.p95State, "small_sample");
  assert.equal(modelB.dropLeftMicroseconds, 120 * minute);
  assert.equal(modelB.dropRightMicroseconds, 122 * minute);
  assert.equal(modelB.dropMicroseconds, 121 * minute);
});

test("all gap values scale both fitted estimates and midpoint", () => {
  const doubled = syntheticPoints().map((point) => ({
    ...point,
    gapMicroseconds: point.gapMicroseconds * 2,
  }));
  const result = calculateCacheRetention(doubled);
  assert.equal(result.p95Microseconds, 228 * minute);
  assert.equal(result.dropLeftMicroseconds, 240 * minute);
  assert.equal(result.dropRightMicroseconds, 242 * minute);
  assert.equal(result.dropMicroseconds, 241 * minute);
});

test("integer high-reuse threshold, nearest-rank thresholds, and empty input", () => {
  const empty = calculateCacheRetention([]);
  assert.equal(empty.count, 0);
  assert.equal(empty.highCount, 0);
  assert.equal(empty.p95Microseconds, null);
  assert.equal(empty.dropMicroseconds, null);
  assert.equal(empty.p95State, "insufficient");
  assert.equal(empty.dropState, "insufficient");

  const threshold = calculateCacheRetention([
    makePoint("threshold-hit", 1, 9, { input: 11 }),
    makePoint("threshold-miss", 2, 8, { input: 11 }),
  ]);
  assert.equal(threshold.highCount, 1);

  for (const count of [19, 20, 39, 99, 100]) {
    const result = calculateCacheRetention(
      Array.from({ length: count }, (_, index) => makePoint(`high-${index}`, index, 1_000)),
    );
    assert.equal(result.highCount, count);
    if (count < 20) {
      assert.equal(result.p95Microseconds, null);
      assert.equal(result.p95State, "insufficient");
    } else {
      const rank = Math.floor((95 * count + 99) / 100);
      assert.equal(result.p95Microseconds, rank - 1);
      assert.equal(result.p95CoverageCount, rank);
      assert.equal(result.p95State, count < 100 ? "small_sample" : "ready");
    }
    if (count < 40) assert.equal(result.dropState, "insufficient");
  }
});

test("nearest-rank coverage counts tied values at the cutoff", () => {
  const points = Array.from({ length: 20 }, (_, index) =>
    makePoint(`tie-${index}`, index < 12 ? 10 : 20, 1_000));
  const result = calculateCacheRetention(points);
  assert.equal(result.p95Microseconds, 20);
  assert.equal(result.p95CoverageCount, 20);
  assert.equal(result.p95State, "small_sample");
});

test("equal gaps stay in one tie group and uniform high or low data has no drop", () => {
  const equalGap = Array.from({ length: 40 }, (_, index) =>
    makePoint(`same-gap-${index}`, 7, index < 20 ? 1_000 : 0));
  const tied = calculateCacheRetention(equalGap);
  assert.equal(tied.searchMode, "exact");
  assert.equal(tied.bestSegments, null);
  assert.deepEqual(tied.segments, []);
  assert.equal(tied.dropMicroseconds, null);
  assert.equal(tied.dropState, "insufficient");

  for (const cached of [1_000, 0]) {
    const uniform = calculateCacheRetention(
      Array.from({ length: 160 }, (_, index) => makePoint(`uniform-${index}`, index + 1, cached)),
    );
    assert.equal(uniform.dropMicroseconds, null);
    assert.equal(uniform.dropState, "not_detected");
    assert.equal(uniform.bestSegments, 1);
  }
});

test("BIC may select three monotone segments and reports the largest boundary", () => {
  const regime = (name, firstGap, gapCount, highPerGap) =>
    Array.from({ length: gapCount }, (_, gapOffset) =>
      Array.from({ length: 10 }, (_, replicate) => makePoint(
        `${name}-${gapOffset}-${replicate}`,
        firstGap + gapOffset,
        replicate < highPerGap ? 1_000 : 0,
      ))).flat();
  const points = [
    ...regime("high", 1, 100, 9),
    ...regime("middle", 101, 100, 6),
    ...regime("low", 201, 100, 1),
  ];
  const result = calculateCacheRetention(points);
  assert.equal(result.bestSegments, 3);
  assert.deepEqual(result.segments.map(({ count }) => count), [1_000, 1_000, 1_000]);
  assert.ok(result.segments[0].rate >= result.segments[1].rate);
  assert.ok(result.segments[1].rate >= result.segments[2].rate);
  assert.equal(result.dropLeftMicroseconds, 200);
  assert.equal(result.dropRightMicroseconds, 201);
  assert.equal(result.dropMicroseconds, 200.5);
});

test("large scopes clear both estimates and safe-integer microseconds are required", () => {
  const large = calculateCacheRetention(
    Array.from({ length: 100_001 }, (_, index) => makePoint(`large-${index}`, index, 1_000)),
  );
  assert.equal(large.count, 100_001);
  assert.equal(large.highCount, 100_001);
  assert.equal(large.p95Microseconds, null);
  assert.equal(large.dropMicroseconds, null);
  assert.equal(large.p95State, "range_too_large");
  assert.equal(large.dropState, "range_too_large");
  assert.equal(large.searchMode, "not_run");

  assert.throws(
    () => calculateCacheRetention([makePoint("unsafe", Number.MAX_SAFE_INTEGER + 1, 1_000)]),
    /gapMicroseconds must be a safe integer/,
  );
});

test("bounded candidate grid preserves a large-scope two-segment break", () => {
  const points = Array.from({ length: 514 }, (_, groupOffset) => {
    const group = groupOffset + 1;
    return Array.from({ length: 20 }, (_, replicate) =>
      makePoint(`grid-${group}-${replicate}`, group, group <= 400 ? 1_000 : 0));
  }).flat();
  const result = calculateCacheRetention(points);
  assert.equal(result.searchMode, "bounded_candidate_grid");
  assert.equal(result.bestSegments, 2);
  assert.equal(result.dropLeftMicroseconds, 400);
  assert.equal(result.dropRightMicroseconds, 401);
  assert.equal(result.dropMicroseconds, 400.5);
});

test("earlier fitting keeps exact two-segment and bounded three-segment searches", () => {
  // 2,200 distinct gaps remain before the main decline. Their 10-observation
  // groups make the two real monotone regimes supported by the 20-row floor.
  const points = [];
  for (let gap = 1; gap <= 2_200; gap += 1) {
    const highCount = gap <= 1_000 ? 9 : 8;
    for (let replicate = 0; replicate < 10; replicate += 1) {
      points.push(makePoint(
        `earlier-${gap}-${replicate}`,
        gap,
        replicate < highCount ? 1_000 : 0,
      ));
    }
  }
  for (let replicate = 0; replicate < 20; replicate += 1) {
    points.push(makePoint(`main-low-${replicate}`, 2_201, 0));
  }

  const result = calculateCacheRetention(points);
  assert.equal(result.searchMode, "bounded_candidate_grid");
  assert.equal(result.earlierDecline?.searchMode, "exact_two_bounded_three");
  assert.ok(result.earlierDecline?.microseconds < result.dropMicroseconds);
  assert.equal(result.earlierDecline?.leftMicroseconds, 1_000);
  assert.equal(result.earlierDecline?.rightMicroseconds, 1_001);
});

function group(gap, highCount) {
  return Array.from({ length: 1_000 }, (_, index) =>
    makePoint(`${gap}-${index}`, gap * minute, index < highCount ? 90 : 0, { input: 100 }));
}

test("nine-point earlier decline remains advice, separate from P95 coverage", () => {
  const result = calculateCacheRetention([
    ...group(1, 900),
    ...group(20, 810),
    ...group(60, 200),
  ]);
  assert.equal(result.dropMicroseconds, 40 * minute);
  assert.equal(result.earlierDecline?.microseconds, 10.5 * minute);
  assert.equal(result.earlierDecline?.count, 2_000);
  assert.deepEqual(result.earlierDecline?.segments.map(({ highCount }) => highCount), [900, 810]);
  assert.match(formatRetentionRecommendation(result), /10\.5 分钟/);

  const singleDrop = calculateCacheRetention([...group(1, 1_000), ...group(60, 200)]);
  assert.notEqual(singleDrop.dropMicroseconds, null);
  assert.notEqual(singleDrop.p95Microseconds, null);
  assert.equal(singleDrop.earlierDecline, null);
  assert.doesNotMatch(formatRetentionRecommendation(singleDrop), /建议尽量/);
});

test("retention copy matches the native seconds, minutes, risk, and coverage wording", () => {
  assert.equal(formatRetentionMinutes(30_000_000), "30 秒");
  assert.equal(formatRetentionMinutes(500_000), "0 秒");
  assert.equal(formatRetentionMinutes(1_500_000), "2 秒");
  assert.equal(formatRetentionMinutes(2_500_000), "2 秒");
  assert.equal(formatRetentionMinutes(-500_000), "-0 秒");
  assert.equal(formatRetentionMinutes(63_000_000), "1.1 分钟");
  assert.equal(formatRetentionMinutes(899_000_000), "15.0 分钟");

  const result = calculateCacheRetention([...group(1, 1_000), ...group(60, 200)]);
  assert.equal(formatRetentionRecommendation(result), "暂未找到更早的下降点");
  assert.equal(formatRetentionRisk(result), "超过约 30.5 分钟后，低命中更常见");
  assert.match(formatRetentionCoverage(result), /^过去高命中的续问，95% 在约 /);
  assert.doesNotMatch(formatRetentionCoverage(result), /建议|推荐/);

  const empty = calculateCacheRetention([]);
  assert.equal(formatRetentionRecommendation(empty), "暂未找到可靠的续问时间建议");
  assert.equal(formatRetentionRisk(empty), "暂未找到明显风险分界");
  assert.equal(formatRetentionCoverage(empty), "正在积累高命中历史");
});

const goldenDir = process.env.CACHE_RETENTION_GOLDEN_DIR;
test("optional local-only real-point golden matches native summary", { skip: !goldenDir }, async () => {
  const [pointsText, goldenText] = await Promise.all([
    readFile(resolve(goldenDir, "native-points.json"), "utf8"),
    readFile(resolve(goldenDir, "linear80-real-analysis.json"), "utf8"),
  ]);
  const points = JSON.parse(pointsText);
  const golden = JSON.parse(goldenText);
  const result = calculateCacheRetention(points);

  assert.equal(result.count, golden.count);
  assert.equal(result.highCount, golden.highCount);
  assert.equal(result.p95Microseconds, golden.p95Microseconds);
  assert.equal(result.p95CoverageCount, golden.p95CoverageCount);
  assert.equal(result.dropLeftMicroseconds, golden.dropLeftMicroseconds);
  assert.equal(result.dropRightMicroseconds, golden.dropRightMicroseconds);
  assert.equal(result.dropMicroseconds, golden.dropMicroseconds);
  assert.equal(result.bestSegments, golden.bestSegments);
  assert.equal(result.searchMode, golden.searchMode);
  assert.equal(result.earlierDecline?.microseconds, golden.earlierDecline.microseconds);
  assert.equal(formatRetentionMinutes(result.earlierDecline.microseconds), "15.0 分钟");
  assert.equal(result.dropMicroseconds / minute, 49.425);
  assert.ok(Math.abs(result.p95Microseconds / minute - 26.066666666666666) < 1e-12);
});

test("near-equivalent early fits choose the larger decline when a few new samples swap optima", () => {
  const cohorts = [
    [[1778, 1417], [583, 429], [163, 115], [263, 158], [321, 48]],
    [[1787, 1426], [585, 431], [165, 117], [260, 158], [327, 50]],
  ];
  for (const cohort of cohorts) {
    const points = cohort.flatMap(([count, high], group) => Array.from({ length: count }, (_, index) => ({
      id: `${group}-${index}`, sourceKey: "synthetic", sessionKey: "synthetic", model: "synthetic",
      gapMicroseconds: [1, 5, 10, 20, 100][group] * 60_000_000,
      startedAtMicroseconds: 0, previousInput: 1000, previousCached: 1000, input: 1000,
      cached: index < high ? 1000 : 0,
    })));
    const result = calculateCacheRetention(points);
    assert.equal(result.earlierDecline.microseconds, 15 * 60_000_000);
    assert.ok(result.dropMicroseconds > result.earlierDecline.microseconds);
    const scaled = calculateCacheRetention(points.map(point => ({ ...point, gapMicroseconds: point.gapMicroseconds * 2 })));
    assert.equal(scaled.earlierDecline.microseconds, 30 * 60_000_000);
  }
});
