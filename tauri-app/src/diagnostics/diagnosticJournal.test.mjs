import assert from "node:assert/strict";
import test from "node:test";
import { createDiagnosticJournal } from "./diagnosticJournal.ts";
import { beginCommandAttempt, recordCommandFailure, clearCommandFailure } from "./localDiagnostics.ts";
import { diagnosticJournal } from "./diagnosticJournal.ts";

test("recovery archives the exact cause and timestamp without inventing a new failure", () => {
 let at = "2026-09-12T00:00:00Z";
 const journal = createDiagnosticJournal(() => at);
 journal.update("quota", "额度读取失败", "HTTP 502 original error");
 at = "2026-09-12T00:01:00Z";
 journal.update("quota", "额度读取失败", "HTTP 502 original error");
 assert.equal(journal.getSnapshot().current[0].count, 2);
 journal.update("quota", "", "");
 assert.equal(journal.getSnapshot().current.length, 0);
 assert.equal(journal.getSnapshot().history[0].firstAt, "2026-09-12T00:00:00Z");
 assert.equal(journal.getSnapshot().history[0].endedAt, at);
 assert.equal(journal.getSnapshot().history[0].detail, "HTTP 502 original error");
 assert.equal(journal.getSnapshot().history[0].outcome, "recovered");
});
test("a changed error is not mislabeled as recovery; history is bounded", () => {
 const journal = createDiagnosticJournal();
 for (let i=0;i<110;i++) journal.update("quota", "失败", String(i));
 assert.equal(journal.getSnapshot().history.length, 100);
 assert.equal(journal.getSnapshot().history[0].outcome, "changed");
 assert.equal(journal.getSnapshot().current[0].detail, "109");
});
test("stale responses cannot clear a newer command failure; successful payload diagnostics remain visible", () => {
 const older=beginCommandAttempt("journal-test");
 const newer=beginCommandAttempt("journal-test");
 recordCommandFailure("journal-test", "new failure", newer);
 clearCommandFailure("journal-test", older, {diagnostics: []});
 assert.ok(diagnosticJournal.getSnapshot().current.some(e=>e.source === "command:journal-test"));
 clearCommandFailure("journal-test", newer, {diagnostics: [{message: "HTTP 503", rawCause:"upstream unavailable"}]});
 assert.ok(!diagnosticJournal.getSnapshot().current.some(e=>e.source === "command:journal-test"));
 assert.match(diagnosticJournal.getSnapshot().current.find(e=>e.source === "data:journal-test").detail, /upstream unavailable/);
 clearCommandFailure("journal-test", newer, {diagnostics: []});
 assert.ok(!diagnosticJournal.getSnapshot().current.some(e=>e.source === "data:journal-test"));
});
