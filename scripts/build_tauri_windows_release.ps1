param(
    [string]$Version = "0.9.0",
    [ValidateSet("x64", "arm64", "both")]
    [string]$Arch = "both",
    [switch]$SkipNpmCi,
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

# Some Windows build hosts disable PowerShell module auto-loading for non-
# interactive sessions.  The release gate uses Get-FileHash for source and
# installer integrity, so load the built-in utility module explicitly.
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

if ($Arch -ne "both") {
    throw "Windows release builds require both x64 and arm64 installers."
}

if ($ProjectRoot) {
    $RootDir = Resolve-Path $ProjectRoot
} else {
    $RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
}
$TauriDir = Join-Path $RootDir "tauri-app"
$TauriConfigPath = Join-Path $TauriDir "src-tauri\tauri.conf.json"
$ReleaseHelper = Join-Path $PSScriptRoot "tauri_windows_release_helper.mjs"
$VersionDir = Join-Path $RootDir ("dist\release\v{0}" -f $Version)
$BuildDir = Join-Path $VersionDir "windows-build"
$RunId = [Guid]::NewGuid().ToString("N")
$StagingDir = Join-Path $VersionDir (".windows-build.staging.{0}" -f $RunId)
$ConfigPath = Join-Path $VersionDir (".windows-build.config.{0}.json" -f $RunId)
$CargoTestDir = Join-Path $VersionDir (".windows-build.cargo-test.{0}" -f $RunId)
$UserCargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $UserCargoBin) {
    $env:PATH = "$UserCargoBin;$env:PATH"
}
$BuiltAssets = New-Object System.Collections.Generic.List[object]
$Published = $false

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Find-FirstCommand {
    param([string[]]$Names)
    foreach ($Name in $Names) {
        $Command = Get-Command $Name -ErrorAction SilentlyContinue
        if ($null -ne $Command) {
            return $Command.Source
        }
    }
    return $null
}

function Assert-WindowsNativeToolchain {
    $Compiler = Find-FirstCommand @("cl.exe", "clang-cl.exe")
    $Linker = Find-FirstCommand @("link.exe", "lld-link.exe")
    $VsWhereCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $VsWhere = $VsWhereCandidates | Select-Object -First 1
    $WindowsSdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $WindowsSdk = if (Test-Path -LiteralPath $WindowsSdkRoot) {
        Get-ChildItem -LiteralPath $WindowsSdkRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "x64\link.exe") } |
            Select-Object -First 1
    }

    if (-not $Compiler -and -not $VsWhere) {
        throw "Missing MSVC/LLVM compiler or Visual Studio installation discovery (cl.exe, clang-cl.exe, or vswhere.exe)."
    }
    if (-not $Linker -and -not $WindowsSdk) {
        throw "Missing Windows linker/SDK (link.exe, lld-link.exe, or Windows Kits 10)."
    }

    $CompilerLabel = if ($Compiler) { $Compiler } else { "Visual Studio discovery" }
    $LinkerLabel = if ($Linker) { $Linker } else { "Windows SDK discovery" }
    Write-Host "Windows native toolchain preflight: compiler=$CompilerLabel, linker=$LinkerLabel"
}

function Assert-RustTargetsPreflight {
    $Installed = @(rustup target list --installed)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to enumerate installed Rust targets."
    }
    foreach ($Target in @("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc")) {
        if ($Installed -contains $Target) {
            Write-Host "Rust target available: $Target"
        } else {
            Write-Host "Rust target missing (Build-Target will install it): $Target"
        }
    }
}

function Assert-NsisPreflight {
    $Nsis = Find-FirstCommand @("makensis.exe", "makensis")
    if (-not $Nsis) {
        $Candidates = @(
            (Join-Path $env:LOCALAPPDATA "tauri\NSIS\Bin\makensis.exe"),
            (Join-Path $env:LOCALAPPDATA "tauri\NSIS\makensis.exe")
        ) | Where-Object { Test-Path -LiteralPath $_ }
        $Nsis = $Candidates | Select-Object -First 1
    }
    if (-not $Nsis) {
        throw "Missing NSIS compiler (makensis.exe or the Tauri NSIS cache)."
    }
    Write-Host "NSIS compiler available: $Nsis"
}

function Write-WebView2PreflightNotice {
    $Roots = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients"
    )
    $Installed = @()
    foreach ($Root in $Roots) {
        if (Test-Path -LiteralPath $Root) {
            Get-ChildItem -LiteralPath $Root -ErrorAction SilentlyContinue | ForEach-Object {
                $Properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $DisplayName = @($Properties.name, $Properties.displayName) -join " "
                if ($DisplayName -match "WebView2") {
                    $Installed += $_.PSPath
                }
            }
        }
    }
    $Installed = $Installed | Select-Object -First 1
    if ($Installed) {
        Write-Host "WebView2 runtime registry entry detected: $Installed"
    } else {
        Write-Warning "WebView2 runtime was not detected in the standard registry locations; offline/first-run runtime validation is required on the target Windows machine."
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

function Publish-NoClobber {
    param([string]$Source, [string]$Destination, [string[]]$ExpectedNames)
    $LockPath = "$Destination.publish.lock"
    $Lock = $null
    try {
        $Lock = [IO.File]::Open($LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ([IO.Directory]::Exists($Destination) -or [IO.File]::Exists($Destination)) {
            throw "Build output appeared during build: $Destination"
        }
        $ActualNames = @([IO.Directory]::GetFileSystemEntries($Source) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        if (($ActualNames -join "`n") -ne (($ExpectedNames | Sort-Object) -join "`n")) {
            throw "Unsigned build staging is incomplete."
        }
        [IO.Directory]::Move($Source, $Destination)
        $PublishedNames = @([IO.Directory]::GetFileSystemEntries($Destination) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        if (($PublishedNames -join "`n") -ne (($ExpectedNames | Sort-Object) -join "`n")) {
            throw "Published windows-build set is incomplete."
        }
    } finally {
        if ($null -ne $Lock) { $Lock.Dispose() }
        Remove-Item -Force -ErrorAction SilentlyContinue $LockPath
    }
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
        Invoke-Checked "rustup target add $RustTarget" { rustup target add $RustTarget }
    }

    $BundleDir = Join-Path $TauriDir ("src-tauri\target\{0}\release\bundle\nsis" -f $RustTarget)
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $BundleDir
    $BuildStartedAt = [DateTime]::UtcNow

    Push-Location $TauriDir
    try {
        Invoke-Checked "tauri build $RustTarget" {
            npm run tauri -- build --target $RustTarget --config $ConfigPath
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $BundleDir)) {
        throw "NSIS output directory not found: $BundleDir"
    }
    $Installers = @(Get-ChildItem -Path $BundleDir -File -Filter "*.exe")
    if ($Installers.Count -ne 1) {
        throw "Expected exactly one fresh NSIS installer in $BundleDir; found $($Installers.Count)."
    }
    $Installer = $Installers[0]
    if ($Installer.LastWriteTimeUtc -lt $BuildStartedAt.AddSeconds(-2)) {
        throw "NSIS installer predates this build: $($Installer.Name)"
    }
    $InstallerPattern = "^Codex Token Bar_" + [regex]::Escape($Version) + "_" + [regex]::Escape($Label) + "-setup\.exe$"
    if ($Installer.Name -notmatch $InstallerPattern) {
        throw "NSIS installer name does not match version ${Version}: $($Installer.Name)"
    }

    $OutputName = "CodexTokenBar-v$Version-windows-$Label-setup.exe"
    $OutputPath = Join-Path $StagingDir $OutputName
    Copy-Item $Installer.FullName $OutputPath
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
}

if (Test-Path -LiteralPath $BuildDir) {
    throw "Build output already exists: $BuildDir"
}
if (-not (Test-Path -LiteralPath $TauriConfigPath)) {
    throw "Tracked tauri config not found: $TauriConfigPath"
}

Assert-Command "node"
Assert-Command "npm"
Assert-Command "rustc"
Assert-Command "rustup"
Assert-Command "cargo"
Assert-WindowsNativeToolchain
Assert-RustTargetsPreflight
Assert-NsisPreflight
Write-WebView2PreflightNotice

New-Item -ItemType Directory -Force -Path $VersionDir | Out-Null
$TauriConfigHashBefore = (Get-FileHash -Algorithm SHA256 $TauriConfigPath).Hash

try {
    New-Item -ItemType Directory -Path $StagingDir | Out-Null
    Write-Utf8NoBom -Path $ConfigPath -Content ('{"bundle":{"createUpdaterArtifacts":false}}' + [Environment]::NewLine)

    Push-Location $TauriDir
    try {
        if (-not $SkipNpmCi) {
            Invoke-Checked "npm ci" { npm ci }
        }
        Invoke-Checked "npm run build" { npm run build }
    } finally {
        Pop-Location
    }

    Invoke-Checked "thread-delete injection syntax" {
        node --check (Join-Path $RootDir "Resources\CodexThreadDeleteInjection.js")
    }
    Invoke-Checked "session-enhancement injection syntax" {
        node --check (Join-Path $RootDir "Resources\CodexSessionEnhancementsInjection.js")
    }
    Invoke-Checked "release script tests" {
        node --test `
            (Join-Path $PSScriptRoot "tauri_windows_release.test.mjs") `
            (Join-Path $PSScriptRoot "build_tauri_windows_release.test.mjs")
    }

    $HadCargoTargetDir = Test-Path Env:CARGO_TARGET_DIR
    $PreviousCargoTargetDir = $env:CARGO_TARGET_DIR
    try {
        $env:CARGO_TARGET_DIR = $CargoTestDir
        Invoke-Checked "cargo test" {
            cargo test --locked --manifest-path (Join-Path $TauriDir "src-tauri\Cargo.toml") -- --test-threads=1
        }
    } finally {
        if ($HadCargoTargetDir) {
            $env:CARGO_TARGET_DIR = $PreviousCargoTargetDir
        } else {
            Remove-Item Env:\CARGO_TARGET_DIR -ErrorAction SilentlyContinue
        }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $CargoTestDir
    }

    Build-Target -Label "x64" -RustTarget "x86_64-pc-windows-msvc" -UpdaterPlatform "windows-x86_64"
    Build-Target -Label "arm64" -RustTarget "aarch64-pc-windows-msvc" -UpdaterPlatform "windows-aarch64"

    $ManifestPath = Join-Path $StagingDir "build-manifest.json"
    $Manifest = [ordered]@{
        version = $Version
        assets = @($BuiltAssets | Sort-Object Platform)
    }
    Write-Utf8NoBom -Path $ManifestPath -Content (($Manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine)

    $ValidationAssetList = Join-Path $VersionDir (".windows-build.assets.{0}.json" -f $RunId)
    try {
        Invoke-Checked "build manifest validation" {
            node $ReleaseHelper validate-build $ManifestPath $StagingDir $Version $ValidationAssetList
        }
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $ValidationAssetList
    }

    $StagedFiles = @(Get-ChildItem -Path $StagingDir -File)
    if ($BuiltAssets.Count -ne 2 -or $StagedFiles.Count -ne 3) {
        throw "Unsigned build staging is incomplete."
    }
    if (Test-Path -LiteralPath $BuildDir) {
        throw "Build output appeared during build: $BuildDir"
    }
    $TauriConfigHashBeforePublish = (Get-FileHash -Algorithm SHA256 $TauriConfigPath).Hash
    if ($TauriConfigHashBeforePublish -ne $TauriConfigHashBefore) {
        throw "Tracked tauri config changed before build publication: $TauriConfigPath"
    }
    $ExpectedBuildNames = @(
        "CodexTokenBar-v$Version-windows-x64-setup.exe",
        "CodexTokenBar-v$Version-windows-arm64-setup.exe",
        "build-manifest.json"
    )
    Publish-NoClobber -Source $StagingDir -Destination $BuildDir -ExpectedNames $ExpectedBuildNames
    $Published = $true
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $ConfigPath
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $CargoTestDir
    if (-not $Published) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $StagingDir
    }
    $TauriConfigHashAfter = if (Test-Path -LiteralPath $TauriConfigPath) {
        (Get-FileHash -Algorithm SHA256 $TauriConfigPath).Hash
    } else {
        "missing"
    }
    if ($TauriConfigHashAfter -ne $TauriConfigHashBefore) {
        throw "Tracked tauri config changed during release build: $TauriConfigPath"
    }
}

Write-Host "==> Unsigned Windows build ready"
Write-Host "Directory: $BuildDir"
Write-Host "Build manifest: $(Join-Path $BuildDir 'build-manifest.json')"
