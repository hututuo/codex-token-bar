import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createHash, generateKeyPairSync } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, readdir, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import nodeTest from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const macScript = path.join(scriptsDir, "sign_tauri_windows_release.sh");
const renameHelperSource = path.join(scriptsDir, "rename_no_replace_darwin.c");
const macSigningRuntimeTest = process.platform === "darwin" ? test : test.skip;
const version = "0.7.2";
const installerNames = [
  `CodexTokenBar-v${version}-windows-arm64-setup.exe`,
  `CodexTokenBar-v${version}-windows-x64-setup.exe`,
];
const test = (name, fn) =>
  nodeTest(name, {
    skip: process.platform === "darwin"
      ? false
      : "requires the macOS signing host and Darwin rename semantics",
  }, fn);

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

// 真实 minisign 形态的测试密钥：pubkey 信封进夹具 tauri.conf.json，
// 私钥 PEM 注入 stub 签名器，让门禁跑真实 Blake2b-512 + ed25519 验证。
function minisignTestKey() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  const keyID = createHash("sha256").update(raw).digest().subarray(0, 8);
  const blob = Buffer.concat([Buffer.from("Ed", "ascii"), keyID, raw]);
  const comment = Buffer.from(keyID).reverse().toString("hex").toUpperCase();
  const envelope = Buffer.from(
    `untrusted comment: minisign public key: ${comment}\n${blob.toString("base64")}\n`,
    "utf8",
  ).toString("base64");
  return {
    privateKeyPem: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    keyIDHex: keyID.toString("hex"),
    envelope,
  };
}

async function snapshotDirectory(directory) {
  const snapshot = {};
  for (const name of (await readdir(directory)).sort()) {
    snapshot[name] = await readFile(path.join(directory, name));
  }
  return snapshot;
}

async function makeFixture(options = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "token-bar-release-"));
  const buildDir = path.join(root, "windows-build");
  const releaseDir = path.join(root, "windows");
  await mkdir(buildDir);
  const assets = [
    ["windows-x86_64", "x64", installerNames[1], "fixture-x64"],
    ["windows-aarch64", "arm64", installerNames[0], "fixture-arm64"],
  ];
  const manifestAssets = [];
  for (const [platform, arch, filename, content] of assets) {
    const file = path.join(buildDir, filename);
    await writeFile(file, content);
    manifestAssets.push({
      version,
      platform,
      arch,
      filename,
      bytes: (await stat(file)).size,
      sha256: sha256(content),
    });
  }
  if (options.badHash) manifestAssets[0].sha256 = "0".repeat(64);
  if (options.missingArch) manifestAssets.pop();
  await writeFile(
    path.join(buildDir, "build-manifest.json"),
    `${JSON.stringify({ version, assets: manifestAssets }, null, 2)}\n`,
  );
  if (options.missingFile) {
    const { rm } = await import("node:fs/promises");
    await rm(path.join(buildDir, assets[0][2]));
  }
  if (options.extraFile) await writeFile(path.join(buildDir, "unexpected.txt"), "unexpected");
  if (options.symlinkInstaller) {
    const { rm } = await import("node:fs/promises");
    const target = path.join(root, "outside.exe");
    await writeFile(target, "fixture-x64");
    await rm(path.join(buildDir, installerNames[1]));
    await symlink(target, path.join(buildDir, installerNames[1]));
  }

  const key = path.join(root, "test.key");
  await writeFile(key, "TEST_PRIVATE_KEY_DO_NOT_LEAK");
  const updaterKey = minisignTestKey();
  const rogueKey = minisignTestKey();
  const verifyConf = path.join(root, "tauri.conf.json");
  await writeFile(
    verifyConf,
    `${JSON.stringify({ plugins: { updater: options.confMissingPubkey ? {} : { pubkey: updaterKey.envelope } } }, null, 2)}\n`,
  );
  const signingKey = options.wrongKeySignature ? rogueKey : updaterKey;
  const signerProgram = path.join(root, "stub-signer.mjs");
  await writeFile(signerProgram, `
import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
const file = process.argv.at(-1);
if (${Boolean(options.finalConflict)} && file.includes("arm64")) {
  const conflict = process.env.RELEASE_CONFLICT_DIR;
  if (conflict) { const { mkdirSync, writeFileSync: writeConflict } = await import("node:fs"); mkdirSync(conflict); writeConflict(new URL("old.txt", "file://" + conflict + "/"), "OLD"); }
}
if (${Boolean(options.failSign)} && file.includes("arm64")) process.exit(42);
const name = path.basename(file);
const privateKey = createPrivateKey(${JSON.stringify(signingKey.privateKeyPem)});
const keyID = Buffer.from(${JSON.stringify(options.wrongSignatureKeyID ? "00112233445566ff" : updaterKey.keyIDHex)}, "hex");
const digest = createHash("blake2b512").update(readFileSync(file)).digest();
const fileSignature = Buffer.concat([
  Buffer.from(${JSON.stringify(options.badSignatureMagic ? "Ed" : options.unknownSignatureMagic ? "XX" : "ED")}, "ascii"),
  keyID,
  sign(null, digest, privateKey),
]);
const trustedComment = "timestamp:1700000000\\tfile:" + name;
const trustedSignature = sign(
  null,
  Buffer.concat([fileSignature.subarray(10), Buffer.from(trustedComment, "utf8")]),
  privateKey,
);
const publishedComment = ${Boolean(options.tamperTrustedComment)}
  ? "timestamp:1700000001\\tfile:" + name
  : trustedComment;
const signatureBody = ${Boolean(options.badSignatureLength)} ? fileSignature.subarray(0, 73) : fileSignature;
const minisign = [
  "untrusted comment: signature from tauri secret key",
  signatureBody.toString("base64"),
  "trusted comment: " + publishedComment,
  trustedSignature.toString("base64"),
].join("\\n") + "\\n";
let envelope = Buffer.from(minisign, "utf8").toString("base64");
if (${Boolean(options.corruptSignature)}) {
  const encoded = Buffer.from(envelope, "ascii");
  encoded[0] ^= 1;
  envelope = encoded.toString("ascii");
}
writeFileSync(file + ".sig", envelope);
`);
  const signer = path.join(root, "stub-signer.sh");
  await writeFile(signer, `#!/bin/sh\nexec '${process.execPath}' '${signerProgram}' "$@"\n`, { mode: 0o755 });

  const binDir = path.join(root, "bin");
  await mkdir(binDir);
  if (options.emptyDestinationRace) {
    await writeFile(
      path.join(binDir, "cc"),
      "#!/bin/sh\nexec /usr/bin/cc -DRENAME_EXCL_TESTING \"$@\"\n",
      { mode: 0o755 },
    );
  }
  if (options.failSecondMktemp) {
    const countFile = path.join(root, "mktemp-count");
    await writeFile(
      path.join(binDir, "mktemp"),
      `#!/bin/sh\ncount=0\n[ ! -f '${countFile}' ] || count=$(cat '${countFile}')\ncount=$((count + 1))\nprintf '%s' "$count" > '${countFile}'\n[ "$count" -ne 2 ] || exit 73\nexec /usr/bin/mktemp "$@"\n`,
      { mode: 0o755 },
    );
  }
  await writeFile(
    path.join(binDir, "file"),
    `#!/bin/sh\nprintf 'called\\n' >> '${path.join(root, "file-calls")}'\nexit 91\n`,
    { mode: 0o755 },
  );
  if (options.useNpmSigner) {
    const npmCalls = path.join(root, "npm-calls.jsonl");
    const npmProgram = path.join(root, "stub-npm.mjs");
    await writeFile(npmProgram, `
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
const passwordState = !("TAURI_SIGNING_PRIVATE_KEY_PASSWORD" in process.env)
  ? "unset"
  : process.env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD === "" ? "empty" : "nonempty";
appendFileSync(${JSON.stringify(npmCalls)}, JSON.stringify({ argv: process.argv.slice(2), passwordState }) + "\\n");
const installer = process.argv.slice(2).find(argument => argument.endsWith(".exe"));
const result = spawnSync(process.execPath, [${JSON.stringify(signerProgram)}, installer], { stdio: "inherit", env: process.env });
process.exit(result.status ?? 1);
`);
    await writeFile(
      path.join(binDir, "npm"),
      `#!/bin/sh\nexec '${process.execPath}' '${npmProgram}' "$@"\n`,
      { mode: 0o755 },
    );
  }
  if (options.swapAfterValidate) {
    await writeFile(
      path.join(binDir, "cp"),
      "#!/bin/sh\ncase \"$1\" in *x64*) printf 'tampered-after-validation' > \"$1\";; esac\nexec /bin/cp \"$@\"\n",
      { mode: 0o755 },
    );
  }
  if (options.failMetadata || options.failChecksum) {
    await writeFile(
      path.join(binDir, "node"),
      `#!/bin/sh\nif [ "$2" = '${options.failMetadata ? "write-metadata" : "write-checksums"}' ]; then exit 43; fi\nexec '${process.execPath}' "$@"\n`,
      { mode: 0o755 },
    );
  }
  if (options.outputExists) {
    await mkdir(releaseDir);
    for (const name of [
      ...installerNames,
      ...installerNames.map(filename => `${filename}.sig`),
      `SHA256SUMS-v${version}-windows.txt`,
      "build-manifest.json",
      "latest-windows.json",
    ]) {
      await writeFile(path.join(releaseDir, name), `OLD_BYTES:${name}`);
    }
  }
  return { root, buildDir, releaseDir, key, signer, binDir, verifyConf };
}

async function runSignerFixture(options = {}) {
  const fixture = await makeFixture(options);
  const buildSnapshot = await snapshotDirectory(fixture.buildDir);
  const outputSnapshot = options.outputExists ? await snapshotDirectory(fixture.releaseDir) : null;
  const env = {
    ...process.env,
    PATH: `${fixture.binDir}:${process.env.PATH}`,
    SOURCE_DATE_EPOCH: "1700000000",
    RELEASE_CONFLICT_DIR: options.finalConflict ? fixture.releaseDir : "",
    RENAME_EXCL_TEST_BARRIER: options.emptyDestinationRace ? path.join(fixture.root, "rename-race") : "",
  };
  if (options.passwordMode === "unset") delete env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD;
  if (options.passwordMode === "empty") env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD = "";
  if (options.passwordMode === "nonempty") env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD = "TEST_SECRET_MUST_NOT_ENTER_ARGV";
  const signerArguments = options.useNpmSigner ? [] : ["--signer", fixture.signer];
  if (options.emptyDestinationRace) {
    const child = spawn("bash", [
      macScript,
      "--version", version,
      "--repo", "hututuo/codex-token-bar",
      "--build-dir", fixture.buildDir,
      "--release-dir", fixture.releaseDir,
      "--key-path", fixture.key,
      "--verify-conf", fixture.verifyConf,
      ...signerArguments,
    ], { env });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    const ready = `${env.RENAME_EXCL_TEST_BARRIER}.ready`;
    for (let attempt = 0; attempt < 500; attempt += 1) {
      try { await access(ready); break; } catch {
        if (attempt === 499) throw new Error(`rename barrier was not reached: ${stderr}`);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    }
    await mkdir(fixture.releaseDir);
    const destinationBefore = await stat(fixture.releaseDir);
    await writeFile(`${env.RENAME_EXCL_TEST_BARRIER}.continue`, "continue");
    const code = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", resolve);
    });
    return { ...fixture, ok: code === 0, code, stdout, stderr, buildSnapshot, outputSnapshot, destinationBefore };
  }
  try {
    const result = await execFileAsync("bash", [
      macScript,
      "--version", version,
      "--repo", "hututuo/codex-token-bar",
      "--build-dir", fixture.buildDir,
      "--release-dir", fixture.releaseDir,
      "--key-path", fixture.key,
      "--verify-conf", fixture.verifyConf,
      ...signerArguments,
    ], { env });
    return { ...fixture, ...result, ok: true, buildSnapshot, outputSnapshot };
  } catch (error) {
    return { ...fixture, ...error, ok: false, buildSnapshot, outputSnapshot };
  }
}

macSigningRuntimeTest("Mac signing treats installer bytes as opaque while manifest binds x64 and ARM64 targets", async () => {
  const result = await runSignerFixture();
  assert.equal(result.ok, true, result.stderr);
  await assert.rejects(access(path.join(result.root, "file-calls")), error => error?.code === "ENOENT");
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
  const names = (await readdir(result.releaseDir)).sort();
  const checksumName = `SHA256SUMS-v${version}-windows.txt`;
  assert.deepEqual(names, [
    ...installerNames,
    ...installerNames.map(name => `${name}.sig`),
    checksumName,
    "build-manifest.json",
    "latest-windows.json",
  ].sort());

  const latest = JSON.parse(await readFile(path.join(result.releaseDir, "latest-windows.json"), "utf8"));
  assert.deepEqual(Object.keys(latest.platforms), ["windows-aarch64", "windows-x86_64"]);
  for (const [platform, entry] of Object.entries(latest.platforms)) {
    const arch = platform === "windows-aarch64" ? "arm64" : "x64";
    assert.match(entry.url, new RegExp(`/CodexTokenBar-v0\\.7\\.2-windows-${arch}-setup\\.exe$`));
    assert.match(entry.signature, /^[A-Za-z0-9+/]+={0,2}$/);
  }

  const lines = (await readFile(path.join(result.releaseDir, checksumName), "utf8")).trim().split("\n");
  assert.equal(lines.length, 6);
  const checksumFiles = lines.map(line => line.split("  ")[1]);
  assert.deepEqual(checksumFiles, [...checksumFiles].sort());
  assert.deepEqual(checksumFiles, names.filter(name => name !== checksumName));
  for (const line of lines) {
    const [expected, filename] = line.split("  ");
    assert.equal(sha256(await readFile(path.join(result.releaseDir, filename))), expected);
  }

  const published = await Promise.all(names.map(name => readFile(path.join(result.releaseDir, name), "utf8")));
  assert.doesNotMatch(published.join("") + result.stdout + result.stderr, /TEST_PRIVATE_KEY_DO_NOT_LEAK/);
});

macSigningRuntimeTest("npm signer distinguishes unset, empty, and nonempty password environments without exposing secrets", async () => {
  for (const passwordMode of ["unset", "empty", "nonempty"]) {
    const result = await runSignerFixture({ useNpmSigner: true, passwordMode });
    assert.equal(result.ok, true, `${passwordMode}: ${result.stderr}`);
    assert.doesNotMatch(result.stdout + result.stderr, /TEST_SECRET_MUST_NOT_ENTER_ARGV/);
    const calls = (await readFile(path.join(result.root, "npm-calls.jsonl"), "utf8"))
      .trim().split("\n").map(line => JSON.parse(line));
    assert.equal(calls.length, 2);
    for (const call of calls) {
      assert.equal(call.passwordState, passwordMode);
      assert.deepEqual(call.argv.slice(0, 7), ["run", "tauri", "--", "signer", "sign", "-f", result.key]);
      assert.equal(call.argv.includes("TEST_SECRET_MUST_NOT_ENTER_ARGV"), false);
      if (passwordMode === "empty") {
        assert.deepEqual(call.argv.slice(-2), ["--password", ""]);
      } else {
        assert.equal(call.argv.includes("--password"), false);
      }
    }
  }
});

macSigningRuntimeTest("Mac signing refuses an existing output directory byte-for-byte", async () => {
  const result = await runSignerFixture({ outputExists: true });
  assert.equal(result.ok, false);
  assert.match(result.stderr, /Release output already exists/);
  assert.deepEqual(await snapshotDirectory(result.releaseDir), result.outputSnapshot);
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
});

macSigningRuntimeTest("Mac rename helper uses Darwin RENAME_EXCL and preserves an empty destination created at the syscall boundary", async () => {
  const source = await readFile(renameHelperSource, "utf8");
  assert.match(source, /renamex_np\s*\([^;]+RENAME_EXCL/);
  assert.match(source, /#ifdef RENAME_EXCL_TESTING[\s\S]+RENAME_EXCL_TEST_BARRIER[\s\S]+#endif/);
  const result = await runSignerFixture({ emptyDestinationRace: true });
  assert.equal(result.ok, false);
  assert.match(result.stderr, /already exists|RENAME_EXCL|publish/i);
  const destinationAfter = await stat(result.releaseDir);
  assert.equal(destinationAfter.dev, result.destinationBefore.dev);
  assert.equal(destinationAfter.ino, result.destinationBefore.ino);
  assert.deepEqual(await readdir(result.releaseDir), []);
  assert.equal((await readdir(result.root)).some(name => name.includes(".windows.staging.")), false);
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
});

macSigningRuntimeTest("Mac signing installs cleanup trap before allocating the rename helper temp file", async () => {
  const source = await readFile(macScript, "utf8");
  assert.ok(source.indexOf("trap cleanup EXIT INT TERM") < source.indexOf('RENAME_HELPER=$(mktemp'));
  const result = await runSignerFixture({ failSecondMktemp: true });
  assert.equal(result.ok, false);
  assert.equal((await readdir(result.root)).some(name => name.includes(".windows.staging.")), false);
  await assert.rejects(access(result.releaseDir), { code: "ENOENT" });
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
});

for (const [name, options, expectedError] of [
  ["missing installer", { missingFile: true }, /Installer .* not found/],
  ["hash mismatch", { badHash: true }, /SHA-256 mismatch/],
  ["missing architecture", { missingArch: true }, /exactly x64 and arm64/],
  ["signer failure", { failSign: true }, /Signer failed/],
  ["non-prehashed signature magic", { badSignatureMagic: true }, /Invalid Tauri signature envelope/],
  ["unknown signature magic", { unknownSignatureMagic: true }, /Invalid Tauri signature envelope/],
  ["invalid file signature length", { badSignatureLength: true }, /Invalid Tauri signature envelope/],
  ["single-byte signature corruption", { corruptSignature: true }, /Invalid Tauri signature envelope/],
  ["signature from an unexpected key", { wrongKeySignature: true }, /Ed25519 verification failed/],
  ["signature key ID mismatch", { wrongSignatureKeyID: true }, /key ID mismatch/i],
  ["tampered trusted comment", { tamperTrustedComment: true }, /Trusted comment verification failed/],
  ["verify configuration without pubkey", { confMissingPubkey: true }, /missing plugins\.updater\.pubkey/],
  ["metadata generation failure", { failMetadata: true }, /Metadata generation failed/],
  ["checksum generation failure", { failChecksum: true }, /Checksum generation failed/],
  ["source replacement after validation", { swapAfterValidate: true }, /staged.*mismatch|mismatch.*staged/i],
  ["symlink installer", { symlinkInstaller: true }, /symbolic link|regular file/i],
  ["extra build input", { extraFile: true }, /exactly two installers and build-manifest/i],
  ["final publication conflict", { finalConflict: true }, /appeared|already exists|publish/i],
]) {
  macSigningRuntimeTest(`Mac signing rejects ${name} without creating the output directory`, async () => {
    const result = await runSignerFixture(options);
    assert.equal(result.ok, false);
    assert.match(result.stderr, expectedError);
    if (options.finalConflict) {
      assert.equal(await readFile(path.join(result.releaseDir, "old.txt"), "utf8"), "OLD");
    } else {
      await assert.rejects(access(result.releaseDir), { code: "ENOENT" });
    }
    assert.equal((await readdir(result.root)).some(name => name.includes(".windows.staging.")), false);
    if (!options.swapAfterValidate) assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
  });
}
