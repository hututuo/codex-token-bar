import assert from "node:assert/strict";
import test from "node:test";

test("startup trace failures stay out of visible local-read diagnostics", async () => {
  const diagnostics = await import("./localDiagnostics.ts");

  diagnostics.clearCommandFailure("record_startup_event");
  diagnostics.recordCommandFailure("record_startup_event", new Error("trace write failed"));

  assert.equal(
    diagnostics
      .getCommandDiagnosticsSnapshot()
      .some((diagnostic) => diagnostic.command === "record_startup_event"),
    false,
  );
});

test("real local-read failures still show in diagnostics", async () => {
  const diagnostics = await import("./localDiagnostics.ts");

  diagnostics.clearCommandFailure("read_dashboard_snapshot");
  diagnostics.recordCommandFailure("read_dashboard_snapshot", new Error("database unavailable"));

  assert.equal(
    diagnostics
      .getCommandDiagnosticsSnapshot()
      .some((diagnostic) => diagnostic.command === "read_dashboard_snapshot"),
    true,
  );

  diagnostics.clearCommandFailure("read_dashboard_snapshot");
});

test("surface platform failures stay out of visible local-read diagnostics", async () => {
  const diagnostics = await import("./localDiagnostics.ts");

  diagnostics.clearCommandFailure("platform:command:show_floating_window");
  diagnostics.recordCommandFailure("platform:command:show_floating_window", new Error("window already opened"));

  assert.equal(
    diagnostics
      .getCommandDiagnosticsSnapshot()
      .some((diagnostic) => diagnostic.command === "platform:command:show_floating_window"),
    false,
  );
});

test("local diagnostics evict old command failures instead of growing forever", async () => {
  const diagnostics = await import("./localDiagnostics.ts");

  for (let index = 0; index < 80; index += 1) {
    diagnostics.recordCommandFailure(`stress_command_${index}`, new Error(`failure ${index}`));
  }

  const snapshot = diagnostics.getCommandDiagnosticsSnapshot();
  assert.ok(snapshot.length <= 50, `expected at most 50 diagnostics, got ${snapshot.length}`);
  assert.equal(snapshot.some((diagnostic) => diagnostic.command === "stress_command_79"), true);
  assert.equal(snapshot.some((diagnostic) => diagnostic.command === "stress_command_0"), false);

  for (let index = 0; index < 80; index += 1) {
    diagnostics.clearCommandFailure(`stress_command_${index}`);
  }
});

test("clearing a command failure removes it from bounded diagnostics", async () => {
  const diagnostics = await import("./localDiagnostics.ts");

  diagnostics.recordCommandFailure("bounded_clear_test", new Error("temporary failure"));
  assert.equal(
    diagnostics.getCommandDiagnosticsSnapshot().some((diagnostic) => diagnostic.command === "bounded_clear_test"),
    true,
  );

  diagnostics.clearCommandFailure("bounded_clear_test");
  assert.equal(
    diagnostics.getCommandDiagnosticsSnapshot().some((diagnostic) => diagnostic.command === "bounded_clear_test"),
    false,
  );
});
