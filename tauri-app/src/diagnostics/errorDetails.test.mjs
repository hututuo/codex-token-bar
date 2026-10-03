import assert from "node:assert/strict";
import test from "node:test";
import { diagnosticErrorText } from "./errorDetails.ts";
import { createDiagnosticJournal, diagnosticEntryText, diagnosticReport } from "./diagnosticJournal.ts";
import { setDiagnosticSource } from "./reportContext.ts";

test("error causes and OS codes survive collection", () => {
  const error = new Error("scan failed", {cause: Object.assign(new Error("access denied"), {code: 5})});
  assert.match(diagnosticErrorText(error), /access denied/);
  assert.match(diagnosticErrorText(error), /"code": 5/);
  assert.match(diagnosticErrorText({code: "operationFailed", message: "missing rollout"}), /missing rollout/);
  assert.equal(diagnosticErrorText(undefined), '"undefined"');
});
test("cyclic and large errors are bounded and credential fields are redacted", () => {
  const error = {message: "Bearer example-credential", access_token: "secret", cause: null};
  error.cause = error;
  const text = diagnosticErrorText(error);
  assert.match(text, /circular/);
  assert.doesNotMatch(text, /example-credential|"secret"/);
  assert.ok(diagnosticErrorText("x".repeat(100000)).length < 17000);
  assert.doesNotMatch(diagnosticErrorText('{"message":"failed","access_token":"private-credential"}'), /private-credential/);
  const normalized = new Error('{"access_token":"private-credential"}');
  Object.defineProperty(normalized, "commandPayload", {value:{code:"failed", access_token:"private-credential"}});
  assert.doesNotMatch(diagnosticErrorText(normalized), /private-credential/);
});
test("source changes do not relabel earlier failures", () => {
  const journal = createDiagnosticJournal();
  const source = path => ({codexHome:{path, source:"default", exists:true}, canonicalHomeKey:path, physicalHomeKey:path, transitionGeneration:1});
  setDiagnosticSource(source("C:\\old"));
  journal.update("scan", "failed", "same failure");
  setDiagnosticSource(source("C:\\new"));
  journal.update("scan", "failed", "same failure");
  assert.match(diagnosticEntryText(journal.getSnapshot().history[0]), /old/);
  assert.match(diagnosticEntryText(journal.getSnapshot().current[0]), /new/);
  assert.match(diagnosticReport(), /版本：\d+\.\d+\.\d+/);
});
