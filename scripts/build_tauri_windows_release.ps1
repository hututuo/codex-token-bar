param(
    [string]$Version = "0.7.2",
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
        $BuildConfig = '{"bundle":{"createUpdaterArtifacts":false}}'
        Invoke-Checked "tauri build $RustTarget" {
            npm run tauri -- build --target $RustTarget --config $BuildConfig
        }
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

    $Size = (Get-Item $OutputPath).Length
    $Hash = (Get-FileHash -Algorithm SHA256 $OutputPath).Hash.ToLowerInvariant()
    $BuiltAssets.Add([pscustomobject]@{
        version = $Version
        platform = $UpdaterPlatform
        arch = $Label
        filename = $OutputName
        bytes = $Size
        sha256 = $Hash
    }) | Out-Null
    Write-Host "Built $OutputName"
    Write-Host "  size=$Size"
    Write-Host "  sha256=$Hash"
}

Assert-Command "node"
Assert-Command "npm"
Assert-Command "rustup"
Assert-Command "cargo"

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

$ManifestPath = Join-Path $ReleaseDir "build-manifest.json"
$Manifest = [ordered]@{
    version = $Version
    assets = @($BuiltAssets | Sort-Object Platform)
}
$ManifestTempPath = "$ManifestPath.tmp"
try {
    Write-Utf8NoBom -Path $ManifestTempPath -Content (($Manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Move-Item -Force $ManifestTempPath $ManifestPath
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $ManifestTempPath
}

Write-Host "==> Unsigned Windows installers ready"
Write-Host "Directory: $ReleaseDir"
Write-Host "Build manifest: $ManifestPath"
