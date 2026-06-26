param(
    [string]$Version = "0.7.0",
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

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Build-Target {
    param(
        [string]$Label,
        [string]$RustTarget
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
        npm run tauri -- build --target $RustTarget | Out-Host
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
        npm ci | Out-Host
    }
    npm run build | Out-Host
} finally {
    Pop-Location
}

$Targets = @()
if ($Arch -eq "x64" -or $Arch -eq "both") {
    $Targets += @{ Label = "x64"; RustTarget = "x86_64-pc-windows-msvc" }
}
if ($Arch -eq "arm64" -or $Arch -eq "both") {
    $Targets += @{ Label = "arm64"; RustTarget = "aarch64-pc-windows-msvc" }
}

foreach ($Target in $Targets) {
    Build-Target -Label $Target.Label -RustTarget $Target.RustTarget
}

$ChecksumPath = Join-Path $ReleaseDir ("SHA256SUMS-v{0}-windows.txt" -f $Version)
$ChecksumLines = Get-ChildItem -Path $ReleaseDir -Filter ("CodexTokenBar-v{0}-windows-*-setup.exe" -f $Version) |
    Sort-Object Name |
    ForEach-Object {
        $Hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        "{0}  {1}" -f $Hash, $_.Name
    }
$ChecksumLines | Set-Content -Path $ChecksumPath -Encoding UTF8

Write-Host "==> Windows release assets ready"
Write-Host "Directory: $ReleaseDir"
Write-Host "Checksums: $ChecksumPath"
