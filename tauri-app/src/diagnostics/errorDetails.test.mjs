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
test("credential syntax is removed from plain errors and nested rendered fields", () => {
  const payloads = [
    "https://fixture-user:synthetic-private-value@example.invalid/retry",
    "https://example.invalid/retry?access_token=synthetic-private-value&attempt=2",
    '{"api_key":"synthetic-private-value","code":13}',
    "refresh_token = 'synthetic-private-value'",
    "password=synthetic-private-value",
    "Authorization: Basic synthetic-private-value",
    "Cookie: session=synthetic-private-value; another=synthetic-second-value",
  ];
  for (const payload of payloads) {
    for (const error of [new Error(payload), {code: 13, cause: {message: payload, path: payload}}]) {
      const text = diagnosticErrorText(error);
      assert.doesNotMatch(text, /synthetic-private-value|synthetic-second-value/, payload);
      assert.match(text, /\[redacted\]/, payload);
      if (!(error instanceof Error)) assert.equal(JSON.parse(text).code, 13);
    }
  }
});
test("redaction precedes string limits and preserves ordinary diagnostic values", () => {
  const error = {message: 'password="' + "Z".repeat(20_000) + '"', code: 13};
  assert.doesNotMatch(diagnosticErrorText(error), /ZZZZ/);
  const text = diagnosticErrorText({code: 5, message: "database is locked; tokens_used=123; totalTokens=456",
    path: "/tmp/token-cache/ledger.sqlite", reason: "writer still active"});
  assert.match(text, /tokens_used=123; totalTokens=456/);
  assert.match(text, /\/tmp\/token-cache\/ledger.sqlite/);
  assert.match(text, /writer still active/);
  assert.match(text, /"code": 5/);
});
test("provider credential assignments are redacted without hiding token counters", () => {
  for (const label of ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN", "AZURE_OPENAI_API_KEY", "SERVICE_CLIENT_SECRET"]) {
    for (const error of [new Error(`${label}=synthetic-provider-secret; tokens_used=123; totalTokens=456`),
      {reason: `${label}=synthetic-provider-secret; tokens_used=123; totalTokens=456`}]) {
      const text = diagnosticErrorText(error);
      assert.doesNotMatch(text, /synthetic-provider-secret/, label);
      assert.ok(text.includes(`${label}=[redacted]`), label);
      assert.match(text, /tokens_used=123; totalTokens=456/);
    }
  }
});
test("credential syntax in object keys is sanitized and prototype names remain plain data", () => {
  const input = JSON.parse('{"__proto__":{"message":"plain data"},"constructor":"plain value"}');
  input["https://fixture.invalid/?access_token=synthetic-key-secret"] = "private value";
  input["https://fixture-user:synthetic-userinfo-value@fixture.invalid/retry"] = "retry failed";
  input.message = "read failed";
  const text = diagnosticErrorText(input);
  assert.doesNotMatch(text, /synthetic-key-secret|synthetic-userinfo-value|private value/);
  const result = JSON.parse(text);
  assert.equal(result["https://fixture.invalid/?access_token=[redacted]"], "[redacted]");
  assert.equal(result["https://[redacted]@fixture.invalid/retry"], "retry failed");
  assert.deepEqual(result.__proto__, {message: "plain data"});
  assert.equal(result.constructor, "plain value");
  assert.equal(result.message, "read failed");
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
