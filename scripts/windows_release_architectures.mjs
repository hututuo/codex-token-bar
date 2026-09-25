// An omitted declaration retains the historical two-architecture contract.
// A partial release must be explicit; a missing installer is never inferred
// to be an intentional change in platform support.
export function windowsReleaseArchitectures(selection = "both") {
  const choices = {
    x64: [{ arch: "x64", platform: "windows-x86_64" }],
    arm64: [{ arch: "arm64", platform: "windows-aarch64" }],
  };
  if (selection === "both") return [...choices.x64, ...choices.arm64];
  if (selection === "x64" || selection === "arm64") return choices[selection];
  throw new Error(`Invalid Windows architecture selection: ${String(selection)}`);
}
