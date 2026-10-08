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
  python scripts/validate_094_index.py before | Out-Host
  Assert-True ($LASTEXITCODE -eq 0) 'Official executable did not produce the expected schema13 index'
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
  $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
  Assert-True (Test-Path $sevenZip) 'Hosted runner has no 7-Zip for independent NSIS payload verification'
  $payloads = @()
  foreach ($arch in @('x64','arm64')) {
    $installer = (Resolve-Path "candidate/CodexTokenBar-v0.9.4-windows-$arch-setup.exe").Path
    & $sevenZip t $installer | Out-File "upgrade-evidence/archive-$arch.log"
    Assert-True ($LASTEXITCODE -eq 0) "NSIS archive integrity failed for $arch"
    $unpack = Join-Path $env:RUNNER_TEMP "candidate-extracted-$arch"
    & $sevenZip x -y "-o$unpack" $installer | Out-File "upgrade-evidence/extract-$arch.log"
    Assert-True ($LASTEXITCODE -eq 0) "Cannot extract NSIS payload for $arch"
    $binary = @(Get-ChildItem $unpack -Recurse -File -Filter codex-token-bar.exe)
    Assert-True ($binary.Count -eq 1) "Ambiguous payload executable for $arch"
    $bytes = [IO.File]::ReadAllBytes($binary[0].FullName)
    Assert-True ($bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) 'Payload is not PE'
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    Assert-True ([BitConverter]::ToUInt32($bytes,$offset) -eq 0x00004550) 'Payload PE header differs'
    $machine = [BitConverter]::ToUInt16($bytes,$offset+4)
    $expected = if ($arch -eq 'x64') { 0x8664 } else { 0xaa64 }
    Assert-True ($machine -eq $expected) "Payload architecture mismatch for $arch"
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary[0].FullName)
    Assert-True ($v.ProductVersion -match '^0\.9\.4(?:\.|$)') "Payload version mismatch for $arch"
    $payloads += @{arch=$arch; pe_machine=$machine; version=$v.ProductVersion; sha256=(Get-FileHash $binary[0].FullName).Hash.ToLowerInvariant()}
  }
  $evidence.payloads = $payloads
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
  $env:TOKENBAR_UPGRADE_HOME = $homePath
  $supportPath = Join-Path $env:APPDATA 'CodexTokenBarTauri'
  python scripts/validate_094_index.py fixture
  Assert-True ($LASTEXITCODE -eq 0) 'Cannot prepare synthetic release history'
  Install-Package $old "/S /D=$destination"
  $exe = Join-Path $destination 'codex-token-bar.exe'
  $evidence.old_process = Observe-App $exe '0.9.3'
  $registered = (Get-Item 'HKCU:\Software\codex\Codex Token Bar').GetValue('')
  Assert-True ($registered -eq $destination) 'Old installation registry path differs'
  $links = @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Token Bar.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Token Bar.lnk'))
  Add-Type @'
using System;
using System.Text;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface UpgradeShellLinkW {
 void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr data, uint flags);
}
public static class UpgradeShortcut {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder text,uint length,uint flags);
 public static string FinalPath(string path) {
  using(var file=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
   var text=new StringBuilder(4096);
   uint length=GetFinalPathNameByHandle(file.SafeFileHandle,text,(uint)text.Capacity,0);
   if(length==0 || length>=text.Capacity) throw new IOException("Cannot normalize shortcut target");
   return text.ToString();
  }
 }
 public static string Read(string path) {
  object obj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
  try {
   ((IPersistFile)obj).Load(path,0);
   var text=new StringBuilder(4096);
   ((UpgradeShellLinkW)obj).GetPath(text,text.Capacity,IntPtr.Zero,4);
   return text.ToString();
  } finally { Marshal.FinalReleaseComObject(obj); }
 }
}
'@

  $shell = New-Object -ComObject WScript.Shell
  $before = @($links | Where-Object { Test-Path $_ } | ForEach-Object { @{path=$_; legacy_wscript_target=$shell.CreateShortcut($_).TargetPath; target=[UpgradeShortcut]::Read($_)} })
  $evidence.expected_executable = $exe
  $evidence.expected_executable_normalized = [UpgradeShortcut]::FinalPath($exe)
  $evidence.official_shortcuts = $before
  Assert-True ($before.Count -gt 0) 'Official installation produced no canonical shortcut'
  Save-Evidence
  foreach ($link in $before) {
    try { $link.normalized_target = [UpgradeShortcut]::FinalPath($link.target) }
    catch { $link.normalization_error = $_.Exception.Message; Save-Evidence; throw }
    Save-Evidence
    Assert-True ($link.normalized_target -eq $evidence.expected_executable_normalized) 'Official shortcut points outside old installation'
  }
  $sentinel = Join-Path $supportPath 'upgrade-retention-sentinel.txt'
  New-Item -ItemType Directory $supportPath -Force | Out-Null
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
  Assert-True ($evidence.new_process.sha256 -eq ($payloads | Where-Object { $_.arch -eq 'x64' }).sha256) 'Running executable differs from verified candidate payload'
  Assert-True ((Get-Item 'HKCU:\Software\codex\Codex Token Bar').GetValue('') -eq $destination) 'New installation registry path differs'
  $evidence.shortcuts = @($before | ForEach-Object { $target=[UpgradeShortcut]::Read($_.path); $normalized=[UpgradeShortcut]::FinalPath($target); Assert-True ($normalized -eq $evidence.expected_executable_normalized) 'Updated shortcut target differs'; @{path=$_.path; target=$target; normalized_target=$normalized} })
  Assert-True ((Get-FileHash $sentinel).Hash -eq $sentinelHash) 'Application data sentinel changed'
  $evidence.data_sentinel_retained = $true
  python scripts/validate_094_index.py after
  Assert-True ($LASTEXITCODE -eq 0) 'Real packaged schema13-to14 migration did not retain synthetic history'
  $evidence.index_migration = 'PASS (schema13 created by official 0.9.3 binary, migrated by candidate 0.9.4 binary; synthetic history only)'
  $evidence.status = 'PASS'
  $live | Stop-Process -Force
} catch {
  $evidence.status = 'FAIL'
  $evidence.error = $_.Exception.Message
  throw
} finally { Save-Evidence }
