# Real local Windows PowerShell 5.1 metadata contract, before expensive builds.
# Uses only this process and its loopback listener; never invokes Antigravity.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run this contract in Windows PowerShell 5.1' }
$image = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$source = Get-Content -LiteralPath 'tauri-app/src-tauri/src/core/antigravity_local_rpc/windows_metadata.ps1' -Raw
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $port = $listener.LocalEndpoint.Port
    $cases = @(
        @{ paths=@($image); count=1 },
        @{ paths=@('C:\NoSuchQuotaFixture\other.exe', $image); count=1 },
        @{ paths=@('C:\NoSuchQuotaFixture\other.exe'); count=0 }
    )
    foreach ($case in $cases) {
        $json = ConvertTo-Json -InputObject $case.paths -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $script = $source.Replace('__EXECUTABLES_BASE64__', $encoded).Replace('__PROCESS_IDS__', [string]$PID)
        $result = (& ([scriptblock]::Create($script))) | ConvertFrom-Json
        if (-not $result.complete -or $result.processes.Count -ne $case.count) {
            throw 'Metadata must accept this same-user process only when its exact image is allowed'
        }
        if ($case.count -eq 1) {
            $row = $result.processes[0]
            if ($row.pid -ne $PID -or -not $row.sameUser) { throw 'Metadata identity mismatch' }
            $owned = @($row.ports | Where-Object {
                $_.ownerPid -eq $PID -and $_.port -eq $port -and $_.address -eq '127.0.0.1'
            })
            if ($owned.Count -ne 1) { throw 'Metadata must discover the actual PID-owned loopback listener' }
        }
    }
    # Reproduce the PS5 array defect with a harmless fixture, proving why the
    # extra @() is not interchangeable with assignment from ConvertFrom-Json.
    $json = ConvertTo-Json -InputObject @($image) -Compress
    $legacy = @($json | ConvertFrom-Json)
    $fixed = $json | ConvertFrom-Json
    if ($legacy -icontains $image -or $fixed -inotcontains $image) {
        throw 'Expected PowerShell 5.1 allowlist regression control'
    }
    Write-Output 'PASS: PS5 allowlist regression control, same-user CIM image and PID-owned loopback metadata'
} finally {
    $listener.Stop()
}
