$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$allowedExecutables = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__EXECUTABLES_BASE64__')) | ConvertFrom-Json)
$ids = @(__PROCESS_IDS__)
$rows = @()
foreach ($candidateId in $ids) {
    # Owner and image path are checked before requesting the command line.
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $candidateId" -Property ProcessId,ExecutablePath
    if ($null -eq $process) { continue }
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0) { throw 'Process owner unavailable' }
    if ($owner.Sid -ne $currentSid) { continue }
    $image = ([string]$process.ExecutablePath).Replace('/', '\')
    if ($image.StartsWith('\\?\')) { $image = $image.Substring(4) }
    if ($allowedExecutables -inotcontains $image) { continue }
    $detail = Get-CimInstance Win32_Process -Filter "ProcessId = $candidateId" -Property ProcessId,ExecutablePath,CommandLine
    if ($null -eq $detail) { continue }
    $listeners = @()
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -OwningProcess $candidateId -ErrorAction Stop |
            Where-Object { $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::') } |
            ForEach-Object { @{ address=[string]$_.LocalAddress; port=[int]$_.LocalPort; ownerPid=[uint32]$_.OwningProcess } })
    } catch {
        # No verified listener means no request will be sent; do not guess a port.
        $listeners = @()
    }
    $rows += @{ pid=[uint32]$detail.ProcessId; executable=[string]$detail.ExecutablePath;
        commandLine=[string]$detail.CommandLine; sameUser=$true; ports=$listeners }
}
@{ complete=$true; processes=@($rows) } | ConvertTo-Json -Depth 6 -Compress
