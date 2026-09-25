$ErrorActionPreference = 'Stop'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Visual Studio discovery is unavailable' }
$vs = (& $vswhere -latest -products '*' -property installationPath | Select-Object -First 1)
if (-not $vs) { throw 'Visual Studio installation not found' }
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$arm = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\arm64\cl.exe" -ErrorAction SilentlyContinue
if (-not $arm) { throw 'Hosted image is missing the ARM64 C++ build tools; do not label an x64 binary ARM64' }
$nsis = "${env:ProgramFiles(x86)}\NSIS"
if (-not (Test-Path "$nsis\makensis.exe")) {
    choco install nsis -y --no-progress
    if ($LASTEXITCODE -ne 0) { throw 'NSIS installation failed' }
}
$env:PATH = "$nsis;$env:PATH"
rustup toolchain install 1.93.1 --profile minimal
if ($LASTEXITCODE -ne 0) { throw 'Rust installation failed' }
rustup target add --toolchain 1.93.1 x86_64-pc-windows-msvc aarch64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust targets installation failed' }
