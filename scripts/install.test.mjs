import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import nodeTest from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const installScript = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "install.sh",
);
const version = "9.9.9";
const assetName = "CodexTokenBar.app.zip";
const checksumName = `SHA256SUMS-v${version}.txt`;
const test = (name, fn) =>
  nodeTest(name, {
    skip: process.platform === "darwin" ? false : "requires macOS ditto/xattr install tooling",
  }, fn);

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function fakeDigest(seed) {
  return sha256(`digest:${seed}`);
}

// PATH 桩 curl：/releases/latest 返回 tag 跳转终点 URL，其余 URL 从
// 夹具 assets/ 目录取文件写到 -o 目标；缺文件按 curl -f 的 22 退出。
const curlStub = `#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
args=("$@")
i=0
while [[ $i -lt \${#args[@]} ]]; do
  a="\${args[$i]}"
  case "$a" in
    -o) i=$((i + 1)); out="\${args[$i]}" ;;
    -w) i=$((i + 1)) ;;
    http://*|https://*) url="$a" ;;
  esac
  i=$((i + 1))
done
echo "$url" >> "$CURL_STUB_LOG"
case "$url" in
  */releases/latest)
    printf '%s' "$(cat "$CURL_STUB_ROOT/latest_url.txt")"
    ;;
  *)
    name="\${url##*/}"
    src="$CURL_STUB_ROOT/assets/$name"
    if [[ ! -f "$src" ]]; then
      exit 22
    fi
    cp "$src" "$out"
    ;;
esac
`;

const xattrStub = `#!/usr/bin/env bash
echo "$@" >> "$XATTR_STUB_LOG"
exit 0
`;

async function makeFixture({ tamperAsset = false, dropChecksumManifest = false, dropAssetEntry = false, latestUrl } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "install-sh-"));
  const stubBin = path.join(root, "bin");
  const stubRoot = path.join(root, "stub");
  const assetsDir = path.join(stubRoot, "assets");
  const installDir = path.join(root, "Applications");
  await mkdir(stubBin, { recursive: true });
  await mkdir(assetsDir, { recursive: true });
  await mkdir(installDir, { recursive: true });

  await writeFile(path.join(stubBin, "curl"), curlStub);
  await writeFile(path.join(stubBin, "xattr"), xattrStub);
  await chmod(path.join(stubBin, "curl"), 0o755);
  await chmod(path.join(stubBin, "xattr"), 0o755);

  await writeFile(
    path.join(stubRoot, "latest_url.txt"),
    latestUrl ?? `https://github.com/hututuo/codex-token-bar/releases/tag/v${version}`,
  );

  // 用真实 ditto 打一个最小 .app 压缩包，走 install.sh 的真实解包路径。
  const appDir = path.join(root, "payload", "Codex Token Bar.app");
  await mkdir(path.join(appDir, "Contents"), { recursive: true });
  await writeFile(path.join(appDir, "Contents", "Info.plist"), "fixture-info-plist\n");
  const zipPath = path.join(assetsDir, assetName);
  await execFileAsync("ditto", ["-c", "-k", "--keepParent", appDir, zipPath]);
  const zipHash = sha256(await readFile(zipPath));
  if (tamperAsset) {
    await writeFile(zipPath, Buffer.from("tampered download"));
  }

  // 统一 8 行清单（决策里的前八项），只有本资产的行携带真实哈希。
  const manifestLines = [
    `${fakeDigest("dmg")}  CodexTokenBar-v${version}-macos-arm64.dmg`,
    `${fakeDigest("zip")}  CodexTokenBar-v${version}-macos-arm64.app.zip`,
    `${dropAssetEntry ? `${fakeDigest("other")}  SomethingElse.zip` : `${zipHash}  ${assetName}`}`,
    `${fakeDigest("x64")}  CodexTokenBar-v${version}-windows-x64-setup.exe`,
    `${fakeDigest("x64sig")}  CodexTokenBar-v${version}-windows-x64-setup.exe.sig`,
    `${fakeDigest("arm64")}  CodexTokenBar-v${version}-windows-arm64-setup.exe`,
    `${fakeDigest("arm64sig")}  CodexTokenBar-v${version}-windows-arm64-setup.exe.sig`,
    `${fakeDigest("latest")}  latest-windows.json`,
  ];
  if (!dropChecksumManifest) {
    await writeFile(path.join(assetsDir, checksumName), `${manifestLines.join("\n")}\n`);
  }

  return {
    root,
    installDir,
    curlLog: path.join(stubRoot, "curl.log"),
    xattrLog: path.join(stubRoot, "xattr.log"),
    env: {
      ...process.env,
      PATH: `${stubBin}:${process.env.PATH}`,
      CURL_STUB_ROOT: stubRoot,
      CURL_STUB_LOG: path.join(stubRoot, "curl.log"),
      XATTR_STUB_LOG: path.join(stubRoot, "xattr.log"),
      CODEX_TOKEN_BAR_INSTALL_DIR: installDir,
      CODEX_TOKEN_BAR_NO_OPEN: "1",
    },
  };
}

async function runInstall(fixture, extraEnv = {}) {
  return execFileAsync("bash", [installScript], { env: { ...fixture.env, ...extraEnv } });
}

async function fileExists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function readLog(file) {
  try {
    return await readFile(file, "utf8");
  } catch {
    return "";
  }
}

test("install.sh verifies the pinned checksum and keeps quarantine by default", async () => {
  const fixture = await makeFixture();
  try {
    const { stdout } = await runInstall(fixture);
    assert.match(stdout, /Downloading checksum manifest \(SHA256SUMS-v9\.9\.9\.txt\)/);
    assert.match(stdout, /Checksum verified: [a-f0-9]{64}/);
    assert.match(stdout, /keeps macOS quarantine metadata/);
    assert.match(stdout, /CODEX_TOKEN_BAR_REMOVE_QUARANTINE=1/);

    assert.equal(
      await fileExists(path.join(fixture.installDir, "Codex Token Bar.app", "Contents", "Info.plist")),
      true,
    );
    assert.equal(await readLog(fixture.xattrLog), "", "xattr must not run by default");

    // 资产与清单都必须来自解析后的固定版本 tag，不允许 latest/download 漂移。
    const curlLog = await readLog(fixture.curlLog);
    assert.match(curlLog, /releases\/latest$/m);
    assert.match(curlLog, new RegExp(`releases/download/v${version.replaceAll(".", "\\.")}/${checksumName}`));
    assert.match(curlLog, new RegExp(`releases/download/v${version.replaceAll(".", "\\.")}/CodexTokenBar\\.app\\.zip`));
    assert.doesNotMatch(curlLog, /releases\/latest\/download/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("install.sh removes quarantine only on explicit opt-in", async () => {
  const fixture = await makeFixture();
  try {
    const { stdout } = await runInstall(fixture, { CODEX_TOKEN_BAR_REMOVE_QUARANTINE: "1" });
    assert.match(stdout, /removed at your request/);
    const xattrLog = await readLog(fixture.xattrLog);
    assert.match(xattrLog, /-dr com\.apple\.quarantine .*Codex Token Bar\.app/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("install.sh refuses a tampered download and installs nothing", async () => {
  const fixture = await makeFixture({ tamperAsset: true });
  try {
    await assert.rejects(runInstall(fixture), (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /SHA-256 mismatch for CodexTokenBar\.app\.zip/);
      assert.match(error.stderr, /refusing to install/);
      return true;
    });
    assert.equal(await fileExists(path.join(fixture.installDir, "Codex Token Bar.app")), false);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("install.sh fails closed when the checksum manifest is missing, unless explicitly skipped", async () => {
  const fixture = await makeFixture({ dropChecksumManifest: true });
  try {
    await assert.rejects(runInstall(fixture), (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /Refusing to install without integrity verification/);
      assert.match(error.stderr, /CODEX_TOKEN_BAR_SKIP_VERIFY=1/);
      return true;
    });
    assert.equal(await fileExists(path.join(fixture.installDir, "Codex Token Bar.app")), false);

    const skipped = await runInstall(fixture, { CODEX_TOKEN_BAR_SKIP_VERIFY: "1" });
    assert.match(skipped.stderr, /WARNING: CODEX_TOKEN_BAR_SKIP_VERIFY=1/);
    assert.equal(
      await fileExists(path.join(fixture.installDir, "Codex Token Bar.app", "Contents", "Info.plist")),
      true,
    );
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("install.sh rejects a manifest without exactly one entry for the asset", async () => {
  const fixture = await makeFixture({ dropAssetEntry: true });
  try {
    await assert.rejects(runInstall(fixture), (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /does not contain exactly one entry for CodexTokenBar\.app\.zip/);
      return true;
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("install.sh fails when the latest release version cannot be resolved", async () => {
  const fixture = await makeFixture({
    latestUrl: "https://github.com/hututuo/codex-token-bar/releases",
  });
  try {
    await assert.rejects(runInstall(fixture), (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /could not resolve the latest release version/);
      return true;
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});
