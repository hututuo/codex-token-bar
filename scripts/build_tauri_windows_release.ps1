param(
    [string]$Version = "0.7.2",
    [string]$GitHubRepo = "hututuo/codex-token-bar",
    [ValidateSet("x64", "arm64", "both")]
    [string]$Arch = "both",
    [switch]$SkipNpmCi
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$TauriDir = Join-Path $RootDir "tauri-app"
$ReleaseDir = Join-Path $RootDir ("dist\release\v{0}\windows" -f $Version)
$UserCargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $UserCargoBin) {
    $env:PATH = "$UserCargoBin;$env:PATH"
}
$BuiltAssets = New-Object System.Collections.Generic.List[object]

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Invoke-Checked {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Build-Target {
    param(
        [string]$Label,
        [string]$RustTarget,
        [string]$UpdaterPlatform
    )

    Write-Host "==> Building Windows $Label ($RustTarget)"
    $Sysroot = (& rustc --print sysroot).Trim()
    $TargetRustlib = Join-Path $Sysroot ("lib\rustlib\{0}" -f $RustTarget)
    if (Test-Path $TargetRustlib) {
        Write-Host "Rust target already available: $RustTarget"
    } else {
        rustup target add $RustTarget | Out-Host
    }

    Push-Location $TauriDir
    try {
        Invoke-Checked "tauri build $RustTarget" { npm run tauri -- build --target $RustTarget }
    } finally {
        Pop-Location
    }

    $BundleDir = Join-Path $TauriDir ("src-tauri\target\{0}\release\bundle\nsis" -f $RustTarget)
    if (-not (Test-Path $BundleDir)) {
        throw "NSIS output directory not found: $BundleDir"
    }

    $Installers = Get-ChildItem -Path $BundleDir -Filter "*.exe" | Sort-Object LastWriteTime -Descending
    if ($Installers.Count -lt 1) {
        throw "No NSIS installer found in $BundleDir"
    }

    New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
    $OutputName = "CodexTokenBar-v$Version-windows-$Label-setup.exe"
    $OutputPath = Join-Path $ReleaseDir $OutputName
    Copy-Item -Force $Installers[0].FullName $OutputPath
    $SourceSigPath = "{0}.sig" -f $Installers[0].FullName
    if (-not (Test-Path $SourceSigPath)) {
        throw "Updater signature not found for $($Installers[0].Name). Check TAURI_SIGNING_PRIVATE_KEY_PATH / TAURI_SIGNING_PRIVATE_KEY."
    }
    $OutputSigName = "$OutputName.sig"
    $OutputSigPath = Join-Path $ReleaseDir $OutputSigName
    Copy-Item -Force $SourceSigPath $OutputSigPath

    $Size = (Get-Item $OutputPath).Length
    $Hash = (Get-FileHash -Algorithm SHA256 $OutputPath).Hash.ToLowerInvariant()
    $Signature = (Get-Content -Raw -Path $OutputSigPath).Trim()
    $BuiltAssets.Add([pscustomobject]@{
        Label = $Label
        Platform = $UpdaterPlatform
        Installer = $OutputName
        Signature = $Signature
    }) | Out-Null
    Write-Host "Built $OutputName"
    Write-Host "  size=$Size"
    Write-Host "  sha256=$Hash"
    Write-Host "  sig=$OutputSigName"
}

Assert-Command "node"
Assert-Command "npm"
Assert-Command "rustup"
Assert-Command "cargo"

if (-not $env:TAURI_SIGNING_PRIVATE_KEY_PATH -and -not $env:TAURI_SIGNING_PRIVATE_KEY) {
    throw "Missing Tauri updater signing key. Set TAURI_SIGNING_PRIVATE_KEY_PATH to the private key file before building Windows updater assets."
}
if ($env:TAURI_SIGNING_PRIVATE_KEY_PATH -and -not $env:TAURI_SIGNING_PRIVATE_KEY) {
    if (-not (Test-Path $env:TAURI_SIGNING_PRIVATE_KEY_PATH)) {
        throw "Tauri updater signing key file not found: $env:TAURI_SIGNING_PRIVATE_KEY_PATH"
    }
    $env:TAURI_SIGNING_PRIVATE_KEY = Get-Content -Raw -Path $env:TAURI_SIGNING_PRIVATE_KEY_PATH
}

Push-Location $TauriDir
try {
    if (-not $SkipNpmCi) {
        Invoke-Checked "npm ci" { npm ci }
    }
    Invoke-Checked "npm run build" { npm run build }
} finally {
    Pop-Location
}

$Targets = @()
if ($Arch -eq "x64" -or $Arch -eq "both") {
    $Targets += @{ Label = "x64"; RustTarget = "x86_64-pc-windows-msvc"; UpdaterPlatform = "windows-x86_64" }
}
if ($Arch -eq "arm64" -or $Arch -eq "both") {
    $Targets += @{ Label = "arm64"; RustTarget = "aarch64-pc-windows-msvc"; UpdaterPlatform = "windows-aarch64" }
}

foreach ($Target in $Targets) {
    Build-Target -Label $Target.Label -RustTarget $Target.RustTarget -UpdaterPlatform $Target.UpdaterPlatform
}

$Platforms = [ordered]@{}
foreach ($Asset in $BuiltAssets) {
    $Platforms[$Asset.Platform] = [ordered]@{
        signature = $Asset.Signature
        url = "https://github.com/$GitHubRepo/releases/download/v$Version/$($Asset.Installer)"
    }
}

$LatestJsonPath = Join-Path $ReleaseDir "latest-windows.json"
$UpdateMetadata = [ordered]@{
    version = $Version
    notes = "Codex Token Bar Windows v$Version"
    pub_date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    platforms = $Platforms
}
Write-Utf8NoBom -Path $LatestJsonPath -Content (($UpdateMetadata | ConvertTo-Json -Depth 5) + [Environment]::NewLine)

$ChecksumPath = Join-Path $ReleaseDir ("SHA256SUMS-v{0}-windows.txt" -f $Version)
$ChecksumLines = Get-ChildItem -Path $ReleaseDir -File |
    Where-Object { $_.Name -ne (Split-Path -Leaf $ChecksumPath) } |
    Sort-Object Name |
    ForEach-Object {
        $Hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        "{0}  {1}" -f $Hash, $_.Name
    }
Write-Utf8NoBom -Path $ChecksumPath -Content (($ChecksumLines -join [Environment]::NewLine) + [Environment]::NewLine)

Write-Host "==> Windows release assets ready"
Write-Host "Directory: $ReleaseDir"
Write-Host "Checksums: $ChecksumPath"
Write-Host "Updater metadata: $LatestJsonPath"
