param(
    [Parameter(Mandatory = $true)]
    [string]$HelperPath,
    [string]$LogPath = 'claude-runtime-ipc-smoke.log'
)

# Execute on a disposable Windows cloud runner after the helper has been built.
# This script never builds or replaces the helper, and never changes preferences.
# The fixture only writes temp files. The existing helper can still inspect
# disabled-source default-directory metadata during its normal initialization.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
    throw 'This acceptance gate requires a disposable GitHub-hosted Windows runner; local and self-hosted execution are forbidden.'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$helper = (Resolve-Path -LiteralPath $HelperPath -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $helper -PathType Leaf) -or [IO.Path]::GetExtension($helper) -ne '.exe') {
    throw 'HelperPath must name the cloud-built ClaudeLocalReader.exe.'
}
$log = [IO.Path]::GetFullPath($LogPath)
if (Test-Path -LiteralPath $log) { throw 'Refusing to overwrite existing IPC smoke evidence.' }
$test = 'core::claude_local_runtime::tests::real_helper_ipc::schema1_and_schema2_use_real_worker_pipe'
$previousHelper = $env:TOKENBAR_CLAUDE_IPC_HELPER
try {
    $env:TOKENBAR_CLAUDE_IPC_HELPER = $helper
    @(
        'IPC smoke scope: disposable hosted runner; only synthetic temp fixtures are created or written.',
        'The existing helper may inspect disabled-source default-directory metadata; real preferences and source data are not selected.',
        "Helper apphost SHA256: $((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash)"
    ) | Tee-Object -FilePath $log
    & cargo test --locked --manifest-path (Join-Path $repo 'tauri-app/src-tauri/Cargo.toml') --lib $test -- --exact --ignored --nocapture --test-threads=1 2>&1 |
        Tee-Object -FilePath $log -Append
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Real helper IPC acceptance failed with exit code $code." }
    $output = Get-Content -LiteralPath $log -Raw
    if ($output -notmatch '(?m)^running 1 test\r?$' -or
        $output -notmatch 'test result: ok\. 1 passed; 0 failed; 0 ignored;' -or
        $output -notmatch 'TOKENBAR_CLAUDE_IPC_SMOKE schema=2 clients=2 completions=2 stopped=disabled' -or
        $output -notmatch 'TOKENBAR_CLAUDE_IPC_SMOKE schema=1 clients=2 completions=2 stopped=registry') {
        throw 'IPC acceptance must execute exactly one passing test and both real schema/lifecycle stages.'
    }
    Write-Output 'Real Rust-spawned Claude helper IPC acceptance passed for schema 2 and legacy schema 1.'
}
finally {
    if ($null -eq $previousHelper) {
        Remove-Item Env:TOKENBAR_CLAUDE_IPC_HELPER -ErrorAction SilentlyContinue
    } else {
        $env:TOKENBAR_CLAUDE_IPC_HELPER = $previousHelper
    }
}
