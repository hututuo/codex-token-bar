$ErrorActionPreference = "Stop"

$BuildScript = Join-Path $PSScriptRoot "build_tauri_windows_release.ps1"
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-token-bar-windows-selftest-{0}" -f [Guid]::NewGuid().ToString("N"))
$global:ReleaseSelfTestRoot = $FixtureRoot
$global:ReleaseSelfTestCalls = New-Object System.Collections.Generic.List[object]
$global:ReleaseSelfTestConfigPaths = New-Object System.Collections.Generic.List[string]
$global:FailArm64 = $false
$global:FailManifest = $false
$global:FinalConflict = $false

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-DirectorySnapshot {
    param([string]$Path)
    $Snapshot = [ordered]@{}
    Get-ChildItem -Path $Path -File | Sort-Object Name | ForEach-Object {
        $Snapshot[$_.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
    }
    return ($Snapshot | ConvertTo-Json -Compress)
}

function global:node {
    if ($args -contains "validate-build") {
        if ($global:FinalConflict) {
            $ConflictDir = Join-Path $global:ReleaseSelfTestRoot "dist\release\v0.7.2\windows-build"
            New-Item -ItemType Directory -Path $ConflictDir | Out-Null
            [IO.File]::WriteAllText((Join-Path $ConflictDir "old.txt"), "OLD_WINDOWS_BUILD")
        }
        if ($global:FailManifest) { $global:LASTEXITCODE = 44; return }
    }
    $global:LASTEXITCODE = 0
}
function global:cargo { $global:LASTEXITCODE = 0 }
function global:rustup { $global:LASTEXITCODE = 0 }
function global:rustc {
    $global:LASTEXITCODE = 0
    if ($args -contains "sysroot") { return (Join-Path $global:ReleaseSelfTestRoot "fake-sysroot") }
}
function global:npm {
    $Arguments = @($args)
    $global:ReleaseSelfTestCalls.Add($Arguments) | Out-Null
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq "run" -and $Arguments[1] -eq "tauri") {
        $BuildIndex = 2
        if ($Arguments.Count -gt 2 -and $Arguments[2] -eq "--") { $BuildIndex = 3 }
        Assert-True ($Arguments.Count -gt $BuildIndex -and $Arguments[$BuildIndex] -eq "build") "tauri argv is missing build"
        $TargetIndex = [Array]::IndexOf($Arguments, "--target")
        $ConfigIndex = [Array]::IndexOf($Arguments, "--config")
        Assert-True ($TargetIndex -eq ($BuildIndex + 1) -and $ConfigIndex -eq ($TargetIndex + 2)) "tauri build argv is missing ordered target or config"
        Assert-True ($Arguments.Count -gt ($ConfigIndex + 1)) "tauri build argv is missing target or config value"
        $Target = $Arguments[$TargetIndex + 1]
        if ($global:FailArm64 -and $Target.StartsWith("aarch64")) {
            $global:LASTEXITCODE = 42
            return
        }
        $Config = $Arguments[$ConfigIndex + 1]
        Assert-True (Test-Path -LiteralPath $Config) "temporary config path was not readable by npm"
        Assert-True (-not $Config.TrimStart().StartsWith("{")) "inline JSON was passed instead of a config path"
        $ParsedConfig = Get-Content -Raw -Path $Config | ConvertFrom-Json
        Assert-True ($ParsedConfig.bundle.createUpdaterArtifacts -eq $false) "updater artifacts were not disabled"
        $global:ReleaseSelfTestConfigPaths.Add($Config) | Out-Null

        $BundleDir = Join-Path $global:ReleaseSelfTestRoot ("tauri-app\src-tauri\target\{0}\release\bundle\nsis" -f $Target)
        Assert-True (-not (Test-Path -LiteralPath $BundleDir)) "stale target NSIS bundle was not removed before build"
        New-Item -ItemType Directory -Force -Path $BundleDir | Out-Null
        $Arch = if ($Target.StartsWith("aarch64")) { "arm64" } else { "x64" }
        $Installer = Join-Path $BundleDir ("Codex Token Bar_0.7.2_{0}-setup.exe" -f $Arch)
        [IO.File]::WriteAllBytes($Installer, [Text.Encoding]::UTF8.GetBytes("fixture-$Arch"))
        (Get-Item $Installer).LastWriteTimeUtc = [DateTime]::UtcNow
    }
    $global:LASTEXITCODE = 0
}

function Initialize-FixtureProject {
    param([string]$Root)
    $TauriConfigDir = Join-Path $Root "tauri-app\src-tauri"
    New-Item -ItemType Directory -Force -Path $TauriConfigDir | Out-Null
    $TauriConfig = Join-Path $TauriConfigDir "tauri.conf.json"
    [IO.File]::WriteAllText($TauriConfig, '{"bundle":{"createUpdaterArtifacts":true}}', (New-Object Text.UTF8Encoding($false)))
    foreach ($Target in @("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root ("fake-sysroot\lib\rustlib\{0}" -f $Target)) | Out-Null
        $StaleBundle = Join-Path $Root ("tauri-app\src-tauri\target\{0}\release\bundle\nsis" -f $Target)
        New-Item -ItemType Directory -Force -Path $StaleBundle | Out-Null
        [IO.File]::WriteAllText((Join-Path $StaleBundle "stale-0.6.0-setup.exe"), "STALE_INSTALLER")
        [IO.File]::WriteAllText((Join-Path $StaleBundle "stale-0.6.0-setup.exe.sig"), "STALE_SIGNATURE")
    }
    return $TauriConfig
}

try {
    $TauriConfig = Initialize-FixtureProject $FixtureRoot

    $ConfigHashBefore = (Get-FileHash -Algorithm SHA256 $TauriConfig).Hash
    & $BuildScript -Version "0.7.2" -Arch both -SkipNpmCi -ProjectRoot $FixtureRoot

    $BuildDir = Join-Path $FixtureRoot "dist\release\v0.7.2\windows-build"
    Assert-True (Test-Path -LiteralPath $BuildDir) "windows-build was not published"
    $Files = @(Get-ChildItem -Path $BuildDir -File | Sort-Object Name)
    Assert-True ($Files.Count -eq 3) "windows-build does not contain exactly two installers and one manifest"
    Assert-True (-not ($Files.Name -match '\.sig$|latest-windows|SHA256SUMS')) "signed or stale metadata leaked into windows-build"
    $Manifest = Get-Content -Raw -Path (Join-Path $BuildDir "build-manifest.json") | ConvertFrom-Json
    Assert-True ($Manifest.version -eq "0.7.2") "build manifest version is unstable"
    Assert-True ($Manifest.assets.Count -eq 2) "build manifest does not contain both architectures"
    Assert-True (($Manifest.assets.platform -join ",") -eq "windows-aarch64,windows-x86_64") "build manifest platform order is unstable"
    foreach ($Asset in $Manifest.assets) {
        Assert-True ($Asset.filename -match "^CodexTokenBar-v0\.7\.2-windows-(arm64|x64)-setup\.exe$") "build manifest filename is invalid"
        Assert-True ($Asset.bytes -gt 0) "build manifest size is invalid"
        Assert-True ($Asset.sha256 -match "^[a-f0-9]{64}$") "build manifest hash is invalid"
    }
    Assert-True ($global:ReleaseSelfTestConfigPaths.Count -eq 2) "expected two tauri build config captures"
    foreach ($Config in $global:ReleaseSelfTestConfigPaths) {
        Assert-True (-not (Test-Path -LiteralPath $Config)) "temporary config was not deleted"
    }
    Assert-True ((Get-FileHash -Algorithm SHA256 $TauriConfig).Hash -eq $ConfigHashBefore) "tracked tauri config changed"

    $SnapshotBefore = Get-DirectorySnapshot $BuildDir
    $CallCountBefore = $global:ReleaseSelfTestCalls.Count
    $FailedAsExpected = $false
    try {
        & $BuildScript -Version "0.7.2" -Arch both -SkipNpmCi -ProjectRoot $FixtureRoot
    } catch {
        $FailedAsExpected = $_.Exception.Message -match "Build output already exists"
    }
    Assert-True $FailedAsExpected "rerun did not reject the existing windows-build directory"
    Assert-True ((Get-DirectorySnapshot $BuildDir) -eq $SnapshotBefore) "existing windows-build changed byte-for-byte"
    Assert-True ($global:ReleaseSelfTestCalls.Count -eq $CallCountBefore) "npm was invoked after existing output rejection"

    foreach ($Scenario in @(
        @{ Name = "arm64-fail"; FailArm64 = $true; FailManifest = $false; FinalConflict = $false },
        @{ Name = "manifest-fail"; FailArm64 = $false; FailManifest = $true; FinalConflict = $false },
        @{ Name = "publish-conflict"; FailArm64 = $false; FailManifest = $false; FinalConflict = $true }
    )) {
        $ScenarioRoot = Join-Path $FixtureRoot $Scenario.Name
        $global:ReleaseSelfTestRoot = $ScenarioRoot
        $global:FailArm64 = $Scenario.FailArm64
        $global:FailManifest = $Scenario.FailManifest
        $global:FinalConflict = $Scenario.FinalConflict
        $ScenarioConfig = Initialize-FixtureProject $ScenarioRoot
        $ScenarioConfigHash = (Get-FileHash -Algorithm SHA256 $ScenarioConfig).Hash
        $ScenarioFailed = $false
        try {
            & $BuildScript -Version "0.7.2" -Arch both -SkipNpmCi -ProjectRoot $ScenarioRoot
        } catch {
            $ScenarioFailed = $true
        }
        Assert-True $ScenarioFailed "$($Scenario.Name) fixture did not fail"
        $ScenarioBuildDir = Join-Path $ScenarioRoot "dist\release\v0.7.2\windows-build"
        if ($Scenario.FinalConflict) {
            Assert-True ((Get-DirectorySnapshot $ScenarioBuildDir) -eq '{"old.txt":"T0xEX1dJTkRPV1NfQlVJTEQ="}') "final publish conflict changed old directory"
        } else {
            Assert-True (-not (Test-Path -LiteralPath $ScenarioBuildDir)) "$($Scenario.Name): windows-build appeared"
        }
        Assert-True ((Get-FileHash -Algorithm SHA256 $ScenarioConfig).Hash -eq $ScenarioConfigHash) "$($Scenario.Name): tracked config changed"
    }
    Write-Host "PASS: Windows release build self-test"
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $FixtureRoot
    Remove-Item Function:\npm -ErrorAction SilentlyContinue
    Remove-Item Function:\rustc -ErrorAction SilentlyContinue
    Remove-Item Function:\rustup -ErrorAction SilentlyContinue
    Remove-Item Function:\cargo -ErrorAction SilentlyContinue
    Remove-Item Function:\node -ErrorAction SilentlyContinue
    Remove-Variable ReleaseSelfTestRoot -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable ReleaseSelfTestCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable ReleaseSelfTestConfigPaths -Scope Global -ErrorAction SilentlyContinue
}
