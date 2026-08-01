import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(scriptsDir, "..");
const windowsScript = path.join(scriptsDir, "build_tauri_windows_release.ps1");
const windowsSelfTest = path.join(scriptsDir, "build_tauri_windows_release.selftest.ps1");
const macReleaseScript = path.join(scriptsDir, "build_release.sh");
const windowsIconGenerator = path.join(scriptsDir, "generate_tauri_windows_icons.py");
const windowsIconDirectory = path.join(projectRoot, "tauri-app", "src-tauri", "icons");
const windowsIconPngs = [
  ["icon.png", 1024],
  ["32x32.png", 32],
  ["128x128.png", 128],
  ["128x128@2x.png", 256],
];
const windowsIcon = path.join(projectRoot, "tauri-app", "src-tauri", "icons", "icon.ico");

function readIcoFrames(encoded) {
  assert.equal(encoded.readUInt16LE(0), 0);
  assert.equal(encoded.readUInt16LE(2), 1);
  const count = encoded.readUInt16LE(4);
  const frames = [];
  for (let index = 0; index < count; index += 1) {
    const directoryOffset = 6 + index * 16;
    const width = encoded[directoryOffset] || 256;
    const height = encoded[directoryOffset + 1] || 256;
    const bytes = encoded.readUInt32LE(directoryOffset + 8);
    const payloadOffset = encoded.readUInt32LE(directoryOffset + 12);
    frames.push({
      width,
      height,
      bitsPerPixel: encoded.readUInt16LE(directoryOffset + 6),
      payload: encoded.subarray(payloadOffset, payloadOffset + bytes),
    });
  }
  return frames;
}

function readGeneratedPng(encoded) {
  assert.equal(encoded.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  let offset = 8;
  let width;
  let height;
  const dataChunks = [];
  while (offset < encoded.length) {
    const length = encoded.readUInt32BE(offset);
    const kind = encoded.subarray(offset + 4, offset + 8).toString("ascii");
    const payload = encoded.subarray(offset + 8, offset + 8 + length);
    if (kind === "IHDR") {
      width = payload.readUInt32BE(0);
      height = payload.readUInt32BE(4);
      assert.equal(payload[8], 8);
      assert.equal(payload[9], 6);
      assert.equal(payload[12], 0);
    } else if (kind === "IDAT") {
      dataChunks.push(payload);
    } else if (kind === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  assert.ok(width && height && dataChunks.length > 0);
  const pixels = inflateSync(Buffer.concat(dataChunks));
  const stride = width * 4 + 1;
  assert.equal(pixels.length, height * stride);
  for (let row = 0; row < height; row += 1) {
    assert.equal(pixels[row * stride], 0);
  }
  const alphaAt = (x, y) => pixels[y * stride + 1 + x * 4 + 3];
  const rgbaAt = (x, y) => {
    const offset = y * stride + 1 + x * 4;
    return [...pixels.subarray(offset, offset + 4)];
  };
  const alpha = [];
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      alpha.push(alphaAt(x, y));
    }
  }
  return { width, height, alphaAt, rgbaAt, alpha };
}

function assertFullBleedRoundedIcon(png) {
  const middle = Math.floor(png.width / 2);
  assert.equal(png.alphaAt(0, 0), 0);
  assert.equal(png.alphaAt(png.width - 1, 0), 0);
  assert.equal(png.alphaAt(0, png.height - 1), 0);
  assert.equal(png.alphaAt(png.width - 1, png.height - 1), 0);
  assert.ok(png.alphaAt(middle, 0) > 240);
  assert.ok(png.alphaAt(middle, png.height - 1) > 240);
  assert.ok(png.alphaAt(0, middle) > 240);
  assert.ok(png.alphaAt(png.width - 1, middle) > 240);
  assert.ok(png.alphaAt(middle, middle) > 240);
  const [bottomRed, , bottomBlue, bottomAlpha] = png.rgbaAt(middle, png.height - 1);
  assert.ok(bottomAlpha > 240);
  assert.ok(bottomRed < 225);
  assert.ok(bottomBlue - bottomRed > 20);
  const transparentPixels = png.alpha.filter(value => value === 0).length;
  assert.ok(transparentPixels > 0);
  assert.ok(transparentPixels < png.width * png.height * 0.08);
  assert.ok(png.alpha.some(value => value > 0 && value < 255));
}

test("Windows application icon is transparent, full-bleed and reproducible at every shell size", async () => {
  const generator = await readFile(windowsIconGenerator, "utf8");
  assert.match(generator, /SOURCE_PATH\s*=.*"Assets".*"AppIcon\.png"/);
  assert.match(generator, /MASTER_SIZE\s*=\s*1024/);
  for (const cropConstant of ["LEFT", "TOP", "WIDTH", "HEIGHT"]) {
    assert.match(generator, new RegExp(`SOURCE_CROP_${cropConstant}\\s*=`));
  }
  assert.match(generator, /apply_squircle_mask/);
  assert.doesNotMatch(generator, /def render_icon/);

  for (const [filename, expectedSize] of windowsIconPngs) {
    const png = readGeneratedPng(await readFile(path.join(windowsIconDirectory, filename)));
    assert.equal(png.width, expectedSize);
    assert.equal(png.height, expectedSize);
    assertFullBleedRoundedIcon(png);
  }

  const frames = readIcoFrames(await readFile(windowsIcon));
  assert.deepEqual(
    frames.map(frame => frame.width),
    [16, 24, 32, 48, 64, 128, 256],
  );
  for (const frame of frames) {
    assert.equal(frame.width, frame.height);
    assert.equal(frame.bitsPerPixel, 32);
    const png = readGeneratedPng(frame.payload);
    assert.equal(png.width, frame.width);
    assert.equal(png.height, frame.height);
    assertFullBleedRoundedIcon(png);
  }
});

test("Windows build publishes a clean unsigned directory in one rename", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /windows-build/);
  assert.match(source, /Build output already exists/);
  assert.match(source, /StagingDir/);
  assert.match(source, /Publish-NoClobber|publish-no-replace/);
  assert.doesNotMatch(source, /Move-Item[^\n]+\$StagingDir[^\n]+\$BuildDir/);
  assert.doesNotMatch(source, /TAURI_SIGNING_PRIVATE_KEY|latest-windows\.json|\.sig\b|SHA256SUMS/);
});

test("Windows build passes a temporary config file and protects tracked config", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /ConfigPath/);
  assert.match(source, /createUpdaterArtifacts/);
  assert.match(source, /--config\s+\$ConfigPath/);
  assert.doesNotMatch(source, /\$BuildConfig\s*=\s*['\"]\{/);
  assert.match(source, /TauriConfigHashBefore/);
  assert.match(source, /Tracked tauri config changed/);
  assert.match(source, /Remove-Item[^\n]+\$ConfigPath/);
});

test("Windows build clears each NSIS output and accepts exactly one fresh versioned installer", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /Remove-Item[^\n]+\$BundleDir/);
  assert.match(source, /Installers\.Count\s+-ne\s+1/);
  assert.match(source, /BuildStartedAt/);
  assert.match(source, /LastWriteTimeUtc/);
  assert.match(source, /Regex.*Version|\[regex\].*Version/i);
  assert.match(source, /InstallerPattern/);
  assert.match(source, /\^Codex Token Bar_/);
  assert.match(source, /setup\\\.exe\$/);
  assert.match(source, /\[regex\]::Escape\(\$Label\)/);
});

test("Windows installer version matching is anchored and rejects a superstring version", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.doesNotMatch("Codex Token Bar_10.7.20_x64-setup.exe", /^Codex Token Bar_0\.7\.2_(x64|arm64)-setup\.exe$/);
  assert.doesNotMatch("Codex Token Bar_0.7.2_arm64-setup.exe", /^Codex Token Bar_0\.7\.2_x64-setup\.exe$/);
  assert.match(source, /\[regex\]::Escape\(\$Version\)/);
});

test("Windows build manifest remains stable and secret-free", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /build-manifest\.json/);
  for (const field of ["version", "platform", "arch", "filename", "bytes", "sha256"]) {
    assert.match(source, new RegExp(`\\b${field}\\b`, "i"));
  }
  assert.match(source, /Sort-Object Platform/);
});

test("release builds run source tests and injection syntax gates before packaging", async () => {
  const windows = await readFile(windowsScript, "utf8");
  const mac = await readFile(macReleaseScript, "utf8");

  assert.match(windows, /cargo test --locked[^\n]*-- --test-threads=1/);
  assert.match(windows, /node --check/);
  assert.match(windows, /node --test/);
  assert.match(windows, /CargoTestDir/);
  assert.match(windows, /Remove-Item[^\n]+\$CargoTestDir/);
  assert.match(mac, /swift test/);
  assert.match(mac, /node --check/);
  assert.match(mac, /node --test/);
  assert.ok(mac.indexOf("swift test") < mac.indexOf("package_app.sh"));
});

test("mac release verifies staged appcast data before publishing history", async () => {
  const source = await readFile(macReleaseScript, "utf8");
  const signatureRead = source.indexOf("read_appcast_signature.py");
  const updateVerify = source.indexOf("sign_update");
  const appVerify = source.indexOf("codesign --verify --deep --strict");
  const publish = source.indexOf("publish_appcast.py");

  assert.match(source, /RELEASE_SECURITY_STRICT="\$\{RELEASE_SECURITY_STRICT:-0\}"/);
  assert.match(source, /MERGED_APPCAST="\$RELEASE_DIR\/appcast\.xml"/);
  assert.ok(signatureRead >= 0);
  assert.ok(updateVerify > signatureRead);
  assert.ok(appVerify > updateVerify);
  assert.ok(publish > appVerify);
  assert.doesNotMatch(source, /re\.search\(r?sparkle:edSignature/);
  assert.match(source, /rm -rf "\$DMG_STAGING" "\$APPCAST_SOURCE_DIR"/);
});

test("PowerShell self-test captures config argv, stale output cleanup, and rerun immutability", async () => {
  const source = await readFile(windowsSelfTest, "utf8");
  assert.match(source, /ReleaseSelfTestCalls/);
  assert.match(source, /--config/);
  assert.match(source, /stale-0\.6\.0-setup\.exe/);
  assert.match(source, /Build output already exists/);
  assert.match(source, /existing windows-build changed byte-for-byte/);
  assert.match(source, /arm64.*fail|FailArm64/i);
  assert.match(source, /manifest.*fail|FailManifest/i);
  assert.match(source, /publish.*conflict|FinalConflict/i);
});

const pwsh = ["pwsh", "powershell"].find(command => {
  try {
    execFileSync(command, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
});

test("PowerShell fixture captures npm argv and preserves an existing build set", { skip: pwsh ? false : "pwsh/powershell unavailable on this Mac" }, () => {
  const result = spawnSync(pwsh, ["-NoProfile", "-File", windowsSelfTest], { encoding: "utf8" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /PASS: Windows release build self-test/);
});
