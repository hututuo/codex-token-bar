$ErrorActionPreference = 'Stop'
$expectedSha = '7e5d0333a68abdd57d008d66bd3e1a1c0f88d6fd'
New-Item -ItemType Directory -Path upgrade-evidence -Force | Out-Null
$evidence = [ordered]@{ source_sha=$expectedSha; build_run='37749712589'; observed_at=(Get-Date).ToUniversalTime().ToString('o'); official_version='0.9.3'; candidate_version='0.9.4'; signed_auto_update='NOT_RUN'; actual_device_ui='NOT_RUN'; status='RUNNING' }
function Save-Evidence { $evidence | ConvertTo-Json -Depth 12 | Set-Content upgrade-evidence/installer-upgrade.json -Encoding utf8 }
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
function Install-Package($package, $arguments) {
  $process = Start-Process -FilePath $package -ArgumentList $arguments -PassThru
  if (-not $process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw 'Installer exceeded two-minute budget' }
  Assert-True ($process.ExitCode -eq 0) "Installer exit code $($process.ExitCode)"
}
function Observe-App($exe, $version) {
  $process = Start-Process -FilePath $exe -PassThru
  Start-Sleep -Seconds 12
  $live = Get-Process -Id $process.Id -ErrorAction Stop
  Assert-True ($live.Path -eq $exe) 'Running executable path differs'
  $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($live.Path)
  Assert-True ($v.ProductVersion -match ('^' + [regex]::Escape($version) + '(?:\.|$)')) "Running product version $($v.ProductVersion) differs"
  $result = @{path=$live.Path; product_version=$v.ProductVersion; sha256=(Get-FileHash $live.Path -Algorithm SHA256).Hash.ToLowerInvariant(); pid=$process.Id}
  Stop-Process -Id $process.Id -Force
  $process.WaitForExit(15000) | Out-Null
  return $result
}
Save-Evidence
try {
  $manifest = Get-Content candidate/candidate-manifest.json -Raw | ConvertFrom-Json
  Assert-True ($manifest.source_sha -eq $expectedSha -and $manifest.version -eq '0.9.4' -and $manifest.workflow_run_id -eq '37749712589') 'Candidate identity differs'
  foreach ($asset in $manifest.assets) {
    $path = Join-Path candidate $asset.name
    Assert-True ((Get-Item $path).Length -eq $asset.bytes) "Candidate size differs: $($asset.name)"
    Assert-True ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $asset.sha256) "Candidate digest differs: $($asset.name)"
  }
  $old = (Resolve-Path official/CodexTokenBar-v0.9.3-windows-x64-setup.exe).Path
  $checksum = Get-Content official/SHA256SUMS-v0.9.3.txt | Where-Object { $_ -match 'CodexTokenBar-v0.9.3-windows-x64-setup.exe$' }
  Assert-True ($checksum.Count -eq 1) 'Official checksum is ambiguous'
  $oldDigest = (Get-FileHash $old -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($oldDigest -eq ($checksum -split '\s+')[0]) 'Official package digest differs'
  $evidence.official_installer_sha256 = $oldDigest
  $new = (Resolve-Path candidate/CodexTokenBar-v0.9.4-windows-x64-setup.exe).Path
  $evidence.candidate_installer_sha256 = (Get-FileHash $new -Algorithm SHA256).Hash.ToLowerInvariant()
  $destination = Join-Path $env:RUNNER_TEMP '升级验证 中文 path\Codex Token Bar'
  $homePath = Join-Path $env:RUNNER_TEMP 'upgrade-synthetic-codex-home'
  New-Item -ItemType Directory $homePath -Force | Out-Null
  $env:CODEX_HOME = $homePath
  $env:CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR = Join-Path $env:RUNNER_TEMP 'upgrade-isolated-support'
  $env:CODEX_TOKEN_BAR_TAURI_CACHE_DIR = Join-Path $env:RUNNER_TEMP 'upgrade-isolated-cache'
  Install-Package $old "/S /D=$destination"
  $exe = Join-Path $destination 'codex-token-bar.exe'
  $evidence.old_process = Observe-App $exe '0.9.3'
  $registered = (Get-Item 'HKCU:\Software\codex\Codex Token Bar').GetValue('')
  Assert-True ($registered -eq $destination) 'Old installation registry path differs'
  $links = @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Token Bar.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Token Bar.lnk'))
  $shell = New-Object -ComObject WScript.Shell
  $before = @($links | Where-Object { Test-Path $_ } | ForEach-Object { @{path=$_; target=$shell.CreateShortcut($_).TargetPath} })
  Assert-True ($before.Count -gt 0) 'Official installation produced no canonical shortcut'
  foreach ($link in $before) { Assert-True ($link.target -eq $exe) 'Official shortcut points outside old installation' }
  $sentinel = Join-Path $env:CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR 'upgrade-retention-sentinel.txt'
  New-Item -ItemType Directory $env:CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR -Force | Out-Null
  Set-Content $sentinel 'synthetic retained application data' -Encoding utf8
  $sentinelHash = (Get-FileHash $sentinel).Hash
  # Exact legacy updater flags; deliberately no /D added by the new updater.
  # Signature download and old-app UI are separate gates and NOT_RUN here.
  $evidence.installer_arguments = '/P /R /UPDATE /ARGS'
  Install-Package $new $evidence.installer_arguments
  Start-Sleep -Seconds 5
  $live = @(Get-Process -Name codex-token-bar -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
  Assert-True ($live.Count -eq 1) 'Legacy /R invocation did not leave exactly one updated process'
  $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($live[0].Path)
  Assert-True ($v.ProductVersion -match '^0\.9\.4(?:\.|$)') "Restarted product version differs: $($v.ProductVersion)"
  $evidence.new_process = @{path=$live[0].Path; product_version=$v.ProductVersion; sha256=(Get-FileHash $exe).Hash.ToLowerInvariant(); pid=$live[0].Id}
  Assert-True ($evidence.old_process.sha256 -ne $evidence.new_process.sha256) 'Executable was not replaced'
  Assert-True ((Get-Item 'HKCU:\Software\codex\Codex Token Bar').GetValue('') -eq $destination) 'New installation registry path differs'
  $evidence.shortcuts = @($before | ForEach-Object { $target=$shell.CreateShortcut($_.path).TargetPath; Assert-True ($target -eq $exe) 'Updated shortcut target differs'; @{path=$_.path; target=$target} })
  Assert-True ((Get-FileHash $sentinel).Hash -eq $sentinelHash) 'Application data sentinel changed'
  $evidence.data_sentinel_retained = $true
  $evidence.index_migration = 'NOT_RUN (no real user index copied or synthesized)'
  $evidence.status = 'PASS'
  $live | Stop-Process -Force
} catch {
  $evidence.status = 'FAIL'
  $evidence.error = $_.Exception.Message
  throw
} finally { Save-Evidence }
