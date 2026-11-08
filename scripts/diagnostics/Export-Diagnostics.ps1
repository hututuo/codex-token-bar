param([string]$OutputPath = "")
$ErrorActionPreference = "Stop"
$Candidates = @((Join-Path $PSScriptRoot 'tokenbar-diagnostics.exe'),
    (Join-Path $PSScriptRoot '..\Diagnostics\tokenbar-diagnostics.exe'),
    (Join-Path $PSScriptRoot '..\codex-token-bar.exe'))
try {
    $Installed = (Get-Item 'HKCU:\Software\codex\Codex Token Bar').GetValue('')
    if ($Installed) { $Candidates += (Join-Path $Installed 'Diagnostics\tokenbar-diagnostics.exe') }
} catch {}
$Helper = $Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $Helper) { throw 'Diagnostic helper missing. Copy tokenbar-diagnostics.exe from the official installer beside this script.' }
$Arguments = @('--export-diagnostics')
if ($OutputPath) { $Arguments += @('--output', $OutputPath) }
& $Helper @Arguments
exit $LASTEXITCODE
