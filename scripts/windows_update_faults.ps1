# Small real NSIS fixture using the exact production hooks. No user registry or data.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP ('tokenbar-update-fixture-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory $root
$hooks = (Resolve-Path 'tauri-app/src-tauri/windows/installer-hooks.nsh').Path
$compiler = (Get-Command makensis.exe -ErrorAction Stop).Source
$payload = Join-Path $root 'payload.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $payload
$payloadHash = (Get-FileHash -LiteralPath $payload).Hash
$script = @'
Unicode true
!include LogicLib.nsh
!include FileFunc.nsh
!include MUI2.nsh
!define PRODUCTNAME "TokenBarUpdateFixture"
!define MAINBINARYNAME "fixture"
!define STARTMENUFOLDER ""
Var PassiveMode
Var UpdateMode
Var NoShortcutMode
Var AppStartMenuFolder
!macro SetLnkAppUserModelId path
!macroend
!include "__HOOKS__"
Name "Token Bar updater fault fixture"
OutFile "__OUT__"
RequestExecutionLevel user
Page instfiles
InstallDir "$TEMP\fixture"
Function .onInit
  ${GetOptions} $CMDLINE "/P" $PassiveMode
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
    SetAutoClose true
  ${EndIf}
  StrCpy $UpdateMode 1
  StrCpy $NoShortcutMode 0
FunctionEnd
Section
  SetOutPath "$INSTDIR"
  !insertmacro NSIS_HOOK_PREINSTALL
  File /oname=fixture.exe "__PAYLOAD__"
  ; Model the upstream ordering: registration after payload copy.
  FileOpen $0 "$INSTDIR\registered.txt" w
  FileWrite $0 "new version"
  FileClose $0
  !insertmacro NSIS_HOOK_POSTINSTALL
  ${If} ${Errors}
    StrCpy $1 "hook error flag set"
  ${Else}
    StrCpy $1 "no hook error flag"
  ${EndIf}
  FileOpen $0 "$INSTDIR\hook-context.txt" w
  FileWrite $0 "programs=$SMPROGRAMS; dir=$INSTDIR; update=$UpdateMode; noShortcut=$NoShortcutMode; $1"
  FileClose $0
SectionEnd
'@
$exe = Join-Path $root 'installer.exe'
$script = $script.Replace('__HOOKS__', $hooks).Replace('__OUT__', $exe).Replace('__PAYLOAD__', $payload)
$nsi = Join-Path $root 'fixture.nsi'
Set-Content -LiteralPath $nsi -Value $script -Encoding utf8
& $compiler /V2 $nsi
if ($LASTEXITCODE -ne 0) { throw 'NSIS fixture compilation failed' }

# Real launch error; ShellExecute return code, not GetLastError, is authoritative.
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.IO;
using System.Text;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices.ComTypes;
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface FixtureShellLinkW {
 void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr data, uint flags);
}
public static class UpdateFaultWindows {
 public static string ReadShortcut(string path) {
   object obj = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
   try {
     ((IPersistFile)obj).Load(path,0);
     var text = new StringBuilder(4096);
     ((FixtureShellLinkW)obj).GetPath(text,text.Capacity,IntPtr.Zero,4);
     return text.ToString();
   } finally { Marshal.FinalReleaseComObject(obj); }
 }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder text,uint length,uint flags);
 public static string FinalPath(string path) {
   using(var file = File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
     var text = new StringBuilder(4096);
     uint length = GetFinalPathNameByHandle(file.SafeFileHandle,text,(uint)text.Capacity,0);
     if(length==0 || length>=text.Capacity) throw new IOException("Cannot normalize shortcut target");
     return text.ToString();
   }
 }
 [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
 public static extern IntPtr ShellExecuteW(IntPtr h,string op,string file,string args,string dir,int show);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)]
 delegate bool EnumWindowsProc(IntPtr h, IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb,IntPtr data);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static bool FaultObserved = false;
 [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint msg,IntPtr wp,IntPtr lp);
 public static void CancelDialogs(int target) {
   EnumWindows((h,_)=>{
     uint pid;GetWindowThreadProcessId(h,out pid);
     if(pid==target) {
       if(GetDlgItem(h,4)!=IntPtr.Zero) {
         FaultObserved = true;
         PostMessage(h,0x111,(IntPtr)2,IntPtr.Zero);
       } else if(FaultObserved && IsWindowEnabled(GetDlgItem(h,2))) {
         // NSIS abort page waits for Close; only dismiss after a real copy fault.
         PostMessage(h,0x111,(IntPtr)2,IntPtr.Zero);
       }
     }
     return true;
   },IntPtr.Zero);
 }
}
'@
$code = [UpdateFaultWindows]::ShellExecuteW([IntPtr]::Zero,'open',(Join-Path $root 'missing.exe'),$null,$null,0).ToInt64()
if ($code -gt 32) { throw 'Missing installer unexpectedly launched' }
Write-Host "PASS ShellExecute failed launch returns $code"

function Run-Fixture([string]$dir, [bool]$silent, [bool]$cancel, [bool]$injectFailure = $false) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.Arguments = $(if($silent){'/S '}else{'/P '}) + '/D=' + $dir
    [UpdateFaultWindows]::FaultObserved = $false
    $p = $null
    $primary = $null
    try {
        $p = [Diagnostics.Process]::Start($start)
        $script:LastFixturePid = $p.Id
        if ($injectFailure) { throw "Injected fixture primary failure" }
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while (-not $p.WaitForExit(150)) {
            if($cancel) { [UpdateFaultWindows]::CancelDialogs($p.Id) }
            if([datetime]::UtcNow -gt $deadline) { throw 'Fixture timed out' }
        }
        if ($cancel -and -not [UpdateFaultWindows]::FaultObserved) { throw 'No real copy-error dialog observed' }
        return $p.ExitCode
    } catch {
        $primary = $_
        throw
    } finally {
        if ($null -ne $p) {
            try {
                if (-not $p.HasExited) {
                    $p.Kill()
                    if (-not $p.WaitForExit(5000)) { throw 'Fixture process did not exit after cleanup' }
                }
            } catch {
                if ($null -ne $primary) { Write-Warning ("Fixture cleanup also failed: " + $_.Exception.Message) }
                else { throw }
            } finally { $p.Dispose() }
        }
    }
}
$link = Join-Path ([Environment]::GetFolderPath('Programs')) 'TokenBarUpdateFixture.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'TokenBarUpdateFixture.lnk'
if ((Test-Path $link) -or (Test-Path $desktopLink)) { throw 'Fixture shortcut collision' }
$primaryFailure = $null
try {
    $cleanupDir = Join-Path $root 'cleanup failure case'
    $null = New-Item -ItemType Directory $cleanupDir
    try {
        Run-Fixture $cleanupDir $false $false $true
        throw 'Injected failure was not raised'
    } catch {
        if ($_.Exception.Message -ne 'Injected fixture primary failure') { throw }
    }
    $remaining = Get-Process -Id $script:LastFixturePid -ErrorAction SilentlyContinue
    if ($remaining) { throw 'Owned installer survived exception cleanup' }
    Write-Host 'PASS fixture preserves primary error and cleans up its own process'
    foreach ($silent in @($true,$false)) {
        $dir = Join-Path $root $(if($silent){'用户 silent dir'}else{'用户 interactive dir'})
        $null = New-Item -ItemType Directory $dir
        $target = Join-Path $dir 'fixture.exe'
        Set-Content -LiteralPath $target -Value 'old payload' -NoNewline
        $lock = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $exit = Run-Fixture $dir $silent (-not $silent)
            if ($exit -eq 0) { throw 'Locked payload unexpectedly reported success' }
            if(Test-Path (Join-Path $dir 'registered.txt')) { throw 'Registered version despite failed payload copy' }
        } finally { $lock.Dispose() }
        if((Get-Content -LiteralPath $target -Raw) -ne 'old payload') { throw 'Old payload was modified during failed install' }
        Write-Host "PASS locked overwrite aborts before registration; silent=$silent"
    }
    $dir = Join-Path $root '用户 successful dir'
    $null = New-Item -ItemType Directory $dir
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $oldTarget = Join-Path $root 'old-copy.exe'
    Copy-Item -LiteralPath $payload -Destination $oldTarget
    $shortcut.TargetPath = $oldTarget
    $shortcut.Save()
    if (-not(Test-Path -LiteralPath $link)) { throw 'Old fixture shortcut was not saved' }
    if ([UpdateFaultWindows]::ReadShortcut($link) -ne $oldTarget) { throw 'Old fixture shortcut target is invalid' }
    $oldLinkHash = (Get-FileHash -LiteralPath $link).Hash
    $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
    $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    if ((Run-Fixture $dir $true $false) -ne 0) { throw 'Unblocked fixture failed' }
    if((Get-FileHash -LiteralPath (Join-Path $dir 'fixture.exe')).Hash -ne $payloadHash) { throw 'Payload mismatch' }
    if(-not(Test-Path (Join-Path $dir 'registered.txt'))) { throw 'Registration marker absent' }
    $reader = New-Object -ComObject WScript.Shell
    $readLink = $reader.CreateShortcut($link)
    $wshTarget = $readLink.TargetPath
    $actualTarget = [UpdateFaultWindows]::ReadShortcut($link)
    $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($readLink)
    $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($reader)
    $expectedTarget = Join-Path $dir 'fixture.exe'
    $newLinkHash = (Get-FileHash -LiteralPath $link).Hash
    Write-Host ("Shortcut expected=" + $expectedTarget + "; actualWide=" + $actualTarget + "; WSH=" + $wshTarget + "; changed=" + ($oldLinkHash -ne $newLinkHash))
    Write-Host (Get-Content -LiteralPath (Join-Path $dir 'hook-context.txt') -Raw)
    if (-not(Test-Path -LiteralPath $actualTarget) -or
        [UpdateFaultWindows]::FinalPath($actualTarget) -ne [UpdateFaultWindows]::FinalPath($expectedTarget)) {
        throw ('Canonical shortcut not repaired: expected=' + $expectedTarget + '; actual=' + $actualTarget)
    }
    Write-Host 'PASS last unquoted /D with Chinese/spaces and canonical shortcut repair'
} catch {
    $primaryFailure = $_
    throw
} finally {
    Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $desktopLink -Force -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $root -Recurse -Force }
    catch {
        if ($null -ne $primaryFailure) { Write-Warning ("Fixture directory cleanup also failed: " + $_.Exception.Message) }
        else { throw }
    }
}
