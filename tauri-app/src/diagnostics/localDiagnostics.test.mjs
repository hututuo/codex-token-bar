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
