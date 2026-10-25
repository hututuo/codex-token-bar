# Agent Speed — Windows Traffic Helper Specification

Per-process network byte counts on Windows are only available to privileged code. This document specifies the small
service that provides them to the per-user app (METRICS 10.3), how it is installed, updated and removed, and its
security model. Everything else about traffic (attribution, rates, history, UI) lives in METRICS 10 and DESIGN 10;
the macOS app needs no helper.

## 1. Why a service, and which account

Measured on the Windows test machine (Windows 11 build 28000, Core Ultra 9 285H, 2026-10-22):

| Who starts the ETW session | Result |
| --- | --- |
| The interactive user's normal (UAC-filtered) token | `StartTrace` → `ERROR_ACCESS_DENIED` (5) |
| `NT AUTHORITY\LOCAL SERVICE` | session created; `EnableTraceEx2` on Microsoft-Windows-Kernel-Network and Microsoft-Windows-Kernel-Process succeed; events received |
| Administrator (elevated) | works |

The per-provider security descriptors on that build (`HKLM\SYSTEM\CurrentControlSet\Control\WMI\Security`):

| Provider | DACL |
| --- | --- |
| Microsoft-Windows-Kernel-Network `{7DD42A49-5329-4832-8DFD-43D979153A88}` | `D:(A;;0x120fff;;;SY)(A;;LO;;;LS)(A;;0x1207ff;;;BA)` — SYSTEM, LOCAL SERVICE (`0x80` = `TRACELOG_GUID_ENABLE`), Administrators |
| Microsoft-Windows-Kernel-Process `{22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716}` | same |
| Default for sessions (`0811c1af-…`) | Everyone register only; SYSTEM, LOCAL SERVICE, NETWORK SERVICE, Administrators full; Performance Log Users `0xee5` |
| NT Kernel Logger (`SystemTraceControlGuid`) | SYSTEM, Administrators and two service SIDs only |

Consequences:

- A **real-time session with the two manifest providers** (not the NT Kernel Logger) is enough, and **LOCAL SERVICE**
  is the least-privileged built-in account allowed to enable them. The service therefore runs as LocalService — not as
  LocalSystem and not as an administrator — although installing it needs administrator approval once.
- The session does **not** fall under the default session descriptor, which would let every LOCAL SERVICE and NETWORK
  SERVICE process, and Performance Log Users (`0xee5` includes `TRACELOG_ACCESS_REALTIME`), consume or stop it. It
  uses a fixed GUID of its own whose descriptor the elevated install sets (section 2, ETW session): SYSTEM and
  Administrators full, the service SID `0x4A1`, no one else. The provider grant to LOCAL SERVICE above is still what
  lets the service enable the providers; measured on build 28000, enabling them into the session *also* needs
  `TRACELOG_GUID_ENABLE` on the session's GUID (`EnableTraceEx2` fails without it), and without `WMIGUID_QUERY` or
  `TRACELOG_ACCESS_REALTIME` on it the consumer receives no events.
- **Performance Log Users** membership (the "no resident service" alternative) does not work: the Kernel-Network
  descriptor does not include that group. Even where it would, it lets every process of the user start sessions for
  most providers on the machine (DNS, WinINet, …), a far broader grant than one service that only hands out byte counts.
- Other options rejected: `GetPerTcpConnectionEStats` (admin to enable, TCP only, misses closed connections);
  WFP callout driver (kernel driver signing); `ConnectionProfile.GetAttributedNetworkUsageAsync` (per application, not
  per process — Gemini CLI and npm installs are just `node.exe`, tool subprocesses cannot be traced to their agent —
  and aggregated by the Data Usage service, not live; not tested further); SRUM (hourly, admin only).

Sources: [StartTrace](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-starttracew)
("Only users with administrative privileges, users in the Performance Log Users group, and services running as
LocalSystem, LocalService, NetworkService can control event tracing sessions … Only users with administrative
privileges and services running as LocalSystem can control an NT Kernel Logger session"),
[ETW security defaults](https://geoffchappell.com/notes/windows/etw/security.htm), and the registry values above.

## 2. Components and files

| Item | Value |
| --- | --- |
| Binary | `AgentSpeedTrafficHelper.exe`, C# compiled with NativeAOT (one file, no runtime, no side-by-side DLLs), x64 and arm64, built by the release workflow (reproducible link, `/Brepro`) and **embedded as a resource in `AgentSpeed.exe`** with its build-time SHA-256; each architecture's `AgentSpeed.exe` carries only its own helper and re-checks the hash before using the bytes. It is not a separate download, so the update flow of UPDATES 5 (one exe) is unchanged. |
| Install location | `%ProgramFiles%\Agent Speed\Traffic Helper\AgentSpeedTrafficHelper.exe` (inherits the Program Files ACL: Administrators, SYSTEM and TrustedInstaller write; Users read and execute). The elevated helper resolves Program Files from `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ProgramFilesDir` (64-bit view, a local `X:\` path), never from the environment; the app from the Program Files known folder. Nothing else is stored there. |
| Service | name `AgentSpeedTraffic`, display name `Agent Speed Traffic Helper`, description "Counts network bytes per process for Agent Speed. Reads no content." (English; Windows shows service descriptions in one language), `SERVICE_WIN32_OWN_PROCESS`, **`SERVICE_DEMAND_START`**, error control normal, account `NT AUTHORITY\LocalService`, ImagePath quoted, no dependencies; accepts only `STOP` and `SHUTDOWN`. |
| Service SID | `SERVICE_SID_TYPE_UNRESTRICTED` (`NT SERVICE\AgentSpeedTraffic`), used as the pipe owner and as the grantee in the ETW session's descriptor. A *restricted* SID type is not used: ETW access checks would then also require the restricted SID, which the provider descriptors do not grant. |
| Required privileges | `SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO` = `SeChangeNotifyPrivilege` only; every other LocalService privilege (notably `SeImpersonatePrivilege` and `SeAssignPrimaryTokenPrivilege`) is removed from the process token. ETW access is granted by the descriptors, not by a privilege (to be confirmed by the first build: the scheduled-task test ran with LocalService's full privilege set). |
| Failure actions | restart after 5 s once; then none (reset after 1 day). They apply when the process ends without reporting `SERVICE_STOPPED` (a crash); `FailureActionsOnNonCrashFailures` is not set, so a stop with an error code (for example a taken pipe name) is not restarted. |
| Service DACL | SYSTEM and Administrators: full (`SERVICE_ALL_ACCESS`). Each **allowed user** (below): `SERVICE_QUERY_STATUS`, `SERVICE_START`, `SERVICE_STOP`, `SERVICE_INTERROGATE`, `READ_CONTROL` (`0x200B4`). Authenticated Users: `SERVICE_QUERY_STATUS`. No one else, and no user gets `SERVICE_CHANGE_CONFIG`, `WRITE_DAC` or `WRITE_OWNER`. |
| Registry | `HKLM\SOFTWARE\AgentSpeed\TrafficHelper` (64-bit view; default HKLM ACL: admins write, users read): `Version` (REG_SZ, `major.minor.patch`, e.g. `1.0.0`), `Protocol` (REG_DWORD, the highest protocol version the installed helper speaks), `AllowedUsers` (REG_MULTI_SZ of user SIDs, at most 64), `InstalledAt` (REG_SZ, UTC `yyyy-MM-ddTHH:mm:ssZ`). |
| ETW session | name `AgentSpeed-Traffic`, real-time, 64 KB buffers, 4 minimum / 32 maximum, flush timer 1 s, `EVENT_TRACE_REAL_TIME_MODE`, QPC clock, fixed session GUID `{6DDF6FEB-235B-49FC-88B8-96907F83D9E0}` (`WNODE_FLAG_TRACED_GUID`). That GUID's own descriptor (its entry under `HKLM\SYSTEM\CurrentControlSet\Control\WMI\Security`) replaces the default session descriptor for this session: SYSTEM and Administrators `0x120FFF` (`WMIGUID_ALL_ACCESS`); the service SID `0x4A1` = `WMIGUID_QUERY` (0x1, query the session) \| `TRACELOG_CREATE_REALTIME` (0x20, start the real-time session) \| `TRACELOG_GUID_ENABLE` (0x80, enable providers into it) \| `TRACELOG_ACCESS_REALTIME` (0x400, consume it); no one else. Every elevated install or update writes it with `EventAccessControl` (`EVENT_SECURITY_SET_DACL` for SYSTEM, then `EVENT_SECURITY_ADD_DACL` for Administrators and the service SID, all allow ACEs), after configuring the service; the remove that deletes the service deletes it with `EventAccessRemove`. The service never changes it. |
| Pipe | `\\.\pipe\AgentSpeed.Traffic` (section 4). |

The *allowed users* are the users who approved the install on this computer: the installer adds the SID of the user who
started it (passed by the app as `--user`) and removes it on that user's uninstall. The SID must be canonical
`S-1-5-21-…` (local, domain and Microsoft accounts) or `S-1-12-1-…` (Microsoft Entra ID) — so no group such as
Everyone or Users can be passed — and LSA must resolve it to a user account (`SidTypeUser`, which rejects domain groups
such as Domain Users). It is accepted only when it is the elevated token's user, its linked (filtered) token's user, or
the user of the parent process that started the elevation (checked to be older than the elevated process; this covers a
standard user who elevated with an administrator's credentials), or when the token has no split
(`TokenElevationTypeDefault`: UAC off, the built-in Administrator, an elevated remote shell — an administrator acting
directly); otherwise the install is refused. At most 64 users are kept. The service only exists while at least one
allowed user remains.

## 3. What the service does

1. **Start** (only through the SCM, by an allowed user's app): `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)`
   first (the binary is also linked with `/DEPENDENTLOADFLAG:0x800`, so even static imports — `kernel32`, `advapi32`,
   `sechost`, `tdh`, `ntdll`, `bcrypt` — resolve from System32 only). It runs as the service only when started without
   command-line arguments (`install` and `remove` are the elevated verbs of section 5; anything else prints usage and
   exits 1, as does a start outside the SCM); SCM start arguments are ignored. It reads `AllowedUsers` once, builds the
   pipe descriptor from it (section 4) and adds `PROCESS_QUERY_LIMITED_INFORMATION` for each allowed user to its own
   process DACL — a LocalService process's default DACL admits only its logon SID and Administrators, so clients could
   not otherwise read its image path (section 4, client step 2); if that fails, clients report `helperDenied`. A user
   added or removed later is therefore seen at the next start. Then, in this order: the pipe (a name already taken ends
   the start with that error), the ETW session and its consumer, the first process listing, `SERVICE_RUNNING`.
2. **Orphan cleanup**: if `StartTrace` reports that a session named `AgentSpeed-Traffic` exists (a previous instance
   crashed — real-time sessions outlive their controller, observed on the test machine), stop it, then start a new one.
   If the session cannot be started or its consumer ends, the service keeps serving with hello flag bit 0 clear and
   tries again every 30 s.
3. **Providers**: Kernel-Network, level 4, keywords `0x30` (IPv4 | IPv6), with an event-ID filter
   (`EVENT_FILTER_TYPE_EVENT_ID`) for 10, 11, 26, 27 (TCP send/receive v4/v6) and 42, 43, 58, 59 (UDP send/receive);
   Kernel-Process, level 4, keyword `0x10` (process), event IDs 1 (start) and 2 (stop). If a provider rejects the
   event-ID filter, it is enabled without it and other IDs are dropped in the callback (they are few: connect,
   disconnect and retransmit events were 2 % of the test trace).
4. **Process table**: at start, one `NtQuerySystemInformation(SystemProcessInformation)` snapshot (PID, parent PID,
   session ID, create time — no handles opened); afterwards the Kernel-Process start/stop events keep it current, plus
   a fresh snapshot every 30 s to heal missed events (live entries missing from it are marked exited). An entry is
   keyed by **(PID, create time)** (FILETIME).
5. **Counting**: for each network event, read `PID` and `size` and both addresses; drop the event when either address
   is loopback (`127.0.0.0/8`, `::1`, `::ffff:127.0.0.0/104`), when `size` is 0, or when PID ≤ 4 (Idle/System).
   Otherwise add `size` to the PID's current entry: receive events (11, 27, 43, 59) to `rx`, send events (10, 26, 42,
   58) to `tx`. Bytes of a PID the table does not know yet (its start event is still in another CPU's buffer, or its
   current entry exited before the event's time) wait as an orphan for up to 5 s (at most 1 024 PIDs) and are credited
   when that process appears; while any wait, the snapshot of step 4 is refreshed every 2 s. An event older than the
   entry's create time is dropped. Field offsets are resolved once per (provider, event ID, version, pointer size) with
   `TdhGetEventInformation` (verified layout on build 28000, version 0: `PID` u32 @0, `size` u32 @4, `daddr` @8,
   `saddr` @12 (IPv4) or @24 (IPv6), ports after); events (network or process) whose layout lacks these fields, or
   whose `UserDataLength` is too short, are counted in `unparsedEvents` and ignored. Addresses and ports are read only
   to make the loopback decision and are never stored.
6. **Process stop**: the entry is marked exited and kept 15 s (so the app's next poll, at most 5 s later per
   METRICS 10.10, sees the final counts), then dropped. The table holds at most 16 384 entries; beyond that, exited
   entries are dropped first (earliest exit first), then the least recently updated (counted in `evictedEntries`).
7. **Idle stop**: when no client has been connected for 120 s (counting only connections the server serves, section 4),
   the service stops its session and exits (`SERVICE_STOPPED`). It therefore runs only while an Agent Speed is sampling
   per-process traffic (section 6).
8. **Stop / shutdown**: report `SERVICE_STOP_PENDING` (wait hint 2 s), `ControlTrace(STOP)`, close the consumer (≤ 1 s)
   and the pipe instances (≤ 0.5 s), exit within 2 s.

Counters are cumulative **since the service saw the process** (not since the process started). Each start of the
service gets a new `epoch` (its start FILETIME), so the app knows when to rebaseline (METRICS 10.4).

Measured consumer cost (a .NET Framework test consumer with the same parsing, on the test machine): 765 events/s
(normal desktop use) → **0.10 %** of one core; a loopback flood at ≈ 1.4 GB/s producing 40 900 events/s → **0.83 %**;
no events or buffers lost; 16 MB working set. A real download of 38.7 MB produced 12 768 receive events (≈ 3 KB per
event) and the per-PID sum matched curl's byte count within 0.16 % (TLS and HTTP overhead). At 1 Gbit/s that is
≈ 40 000 events/s, i.e. under 1 % of one core. Budget: ≤ 0.3 % at idle desktop rates, ≤ 1.5 % at 1 Gbit/s, ≤ 20 MB
working set.

## 4. IPC

**Transport**: one named pipe, `\\.\pipe\AgentSpeed.Traffic`, duplex, byte mode, created with
`FILE_FLAG_FIRST_PIPE_INSTANCE` (for the first instance), `PIPE_REJECT_REMOTE_CLIENTS`, at most 4 instances (all
created at start, each served by its own thread), overlapped I/O, 64 KB out / 4 KB in buffers.

**Pipe security descriptor**: owner `NT SERVICE\AgentSpeedTraffic`; DACL `D:P` (protected) with: an explicit deny
for `NETWORK` (S-1-5-2); SYSTEM full; the service SID full; each allowed user `FILE_GENERIC_READ | FILE_WRITE_DATA`
(`0x12008B`, no create-instance right). An explicit medium mandatory label with no-write-up and no-read-up
(`S:(ML;;NWNR;;;ME)`), so low-integrity and AppContainer processes cannot connect. The allowed users are those of
`AllowedUsers` when the service started.

**Client side** (the app, unprivileged):

1. `CreateFile` with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, so the server can never impersonate the user;
   overlapped I/O, every read or write bounded by 2 s (cancelled and waited for on timeout). `ERROR_FILE_NOT_FOUND`
   or `ERROR_PIPE_BUSY` → not ready yet (keep waiting for the start, section 6); `ERROR_ACCESS_DENIED` →
   `helperDenied`.
2. Verify the server before sending or reading anything: `GetNamedPipeServerProcessId` must equal the `dwProcessId`
   that `QueryServiceStatusEx(AgentSpeedTraffic)` reports for a running service; that process's image path
   (`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `QueryFullProcessImageName`, granted by step 1 of section 3)
   must equal the install location (case-insensitive); and a second `QueryServiceStatusEx` must still report it
   running with the same PID. Any mismatch → disconnect, status `helperDenied` (logged as possible pipe squatting).
3. Snapshots at the per-process sampling interval (METRICS 10.10); while connected without fetching, a `hello` at
   least every 30 s so the server does not drop the connection; never more than 4 requests in any second (checked
   locally before sending).
4. Each response is checked before its payload is read: magic, reserved field, sequence echo, request type, a known
   status whose error flag matches, and a payload length that fits the message; then the payload itself. Snapshot
   entries with PID ≤ 4, create time 0 or a counter above 2⁶³ − 1 are dropped. Any violation, I/O error or timeout
   closes the connection.

**Server side**: the server identifies the client's session with `GetNamedPipeClientSessionId` (no impersonation, no
client PID). Session 0 is refused (an allowed user's batch or service logon would otherwise see the services' and other
users' session-0 processes), and one session may hold at most 2 of the 4 instances; a refused connection is
disconnected unanswered. A snapshot contains **only processes in the client's session** (session from the process
table) with at least one counted byte, so two users on one machine never see each other's per-process traffic.

**Messages** — little-endian, fixed layout, protocol version 1:

| Message | Layout |
| --- | --- |
| Request (exactly 16 bytes) | `u32 magic = 0x48545341` ("ASTH") · `u16 version` · `u16 type` (1 = hello, 2 = snapshot) · `u32 sequence` · `u32 reserved = 0` |
| Response header (32 bytes) | `u32 magic` · `u16 version` (the server's, 1) · `u16 type` (request type; `\| 0x8000` on error) · `u32 status` (0 ok, 1 unsupportedVersion, 2 badRequest, 3 rateLimited, 4 overloaded — reserved, never sent by helper 1.0.0; the app treats it as a failure) · `u32 sequence` (echo) · `u64 epoch` (service start FILETIME) · `u32 payloadLength` · `u32 reserved` |
| Hello payload (40 bytes) | `u16 minProtocol` · `u16 maxProtocol` · `u32 helperVersion` (`major << 16 \| minor << 8 \| patch`) · `u32 flags` (bit 0: the ETW consumer is running) · `u32 reserved` · `u64 eventsLost` (events plus real-time buffers lost by every session of this service run, queried every 5 s) · `u64 unparsedEvents` · `u64 evictedEntries` |
| Snapshot payload | `u64 sampleTime` (FILETIME) · `u32 count` (≤ 16 384) · `u32 reserved` · `count ×` entry (32 bytes): `u32 pid` · `u32 flags` (bit 0 exited) · `u64 createTime` (FILETIME) · `u64 rx` · `u64 tx` |

Validation, in this order: a request that is not exactly 16 bytes (fewer when the rest of a started request does not
arrive within 2 s, more when further bytes are already waiting), has the wrong magic, a non-zero reserved field or an
unknown type gets `badRequest` and the connection is closed (after up to 0.5 s for the client to read the answer); more
than 4 served requests in any second get `rateLimited` (no payload), and 8 rejections in a row close the connection; a
version outside `[minProtocol, maxProtocol]` gets `unsupportedVersion` with the hello payload (so the app can tell what
to update) and the connection stays open. A client that sends nothing for 60 s, or does not read a response within
5 s, is disconnected. The server never allocates based on client input (response buffers grow only with the table).
The protocol is read-only: there is no message that changes anything.

**Versions**: the helper has its own semantic version (independent of the app; the helper project's `<Version>`) and
protocol version. The app embeds `bundledHelperVersion`, `minimumHelperVersion` (raised only for security fixes) and
the protocol range it speaks; currently 1.0.0, 1.0.0 and protocol 1–1.

## 5. Install, update, remove

All privileged steps run in **one elevated process per action**: the embedded helper binary itself, started with
`ShellExecuteEx` (`runas`, hidden window, working directory System32) — one UAC prompt — whose exit code the caller
waits for. It is NativeAOT and loads only System32 DLLs (its manifest is `asInvoker`; only `runas` elevates it);
`AgentSpeed.exe` (a .NET single-file app that extracts native libraries to a user-writable folder) is never run
elevated. Verbs: `install --user <SID> --sha256 <64 hex>` (the two options in either order) and `remove --user <SID>`;
exit code 0 ok, 1 refused (invalid arguments, not an elevated administrator, or a safety check failed), 2 failed.

**Staging** (every elevated run, install and remove): the app checks the embedded bytes against the embedded SHA-256,
creates a new folder `%LOCALAPPDATA%\AgentSpeed\helper-staging\<32 random hex digits>` with a protected DACL (owner and
full control: this user, SYSTEM, Administrators; nothing inherited from the profile), writes the helper there, reads
it back and checks the hash again, and keeps it open (read-only, read sharing only) until the elevated run has exited,
so it cannot be swapped in between. Afterwards it deletes the folder; staging folders older than 1 h left by a crash
are deleted at the next run.

**Install** (Settings → 網路流量 → `traffic.helper.install`, or `install.ps1 -TrafficHelper`):

1. The app shows `traffic.helper.uacNote`, stages the helper and starts it elevated:
   `AgentSpeedTrafficHelper.exe install --user <SID> --sha256 <hex>`.
2. The elevated helper, in this order: checks that it runs with an elevated administrator token; checks `--user`
   (section 2, allowed users); reads its own file (opened without write or delete sharing, at most 64 MB) into memory
   and checks the hash; prepares `%ProgramFiles%\Agent Speed\` and its `Traffic Helper\` folder — each is created
   owned by Administrators with the inherited Program Files ACL, or accepted only when it is a real directory (no
   reparse point) owned by Administrators, TrustedInstaller or SYSTEM in which no ACE for anyone else (CREATOR OWNER
   aside), inherit-only ones included, grants a right that could write, delete or re-permission it; otherwise it
   refuses; stops a running service and waits ≤ 5 s until it is stopped and its process has exited; unless the target
   already is this very file, writes `AgentSpeedTrafficHelper.exe.new` (owner Administrators) from memory, flushes it,
   and renames it over the target (`MoveFileEx` with `REPLACE_EXISTING | WRITE_THROUGH`, retried for up to 3 s while
   the old file is still in use); adds the user to `AllowedUsers` (refused when 64 users are already allowed); writes
   the registry key; creates or reconfigures the service and its DACL (section 2); writes the ETW session's descriptor
   (section 2); and exits with its result code. It does not start the service.
3. The app deletes the staging folder, starts the service (`StartService`), and shows `traffic.helper.installed`; the
   sampler then connects (section 6). A cancelled UAC prompt changes nothing and shows `traffic.helper.cancelled`;
   exit codes 1 and 2 show `traffic.helper.error`.

**Update**: Settings compares the installed `Version` with `bundledHelperVersion` whenever it shows the helper's status.
Newer bundled → Settings shows `traffic.helper.outdated` with `traffic.helper.update` (no prompt appears by itself).
The elevated update is the install sequence (which stops a running service first); the app starts the service again
afterwards. If the user does not update:

- installed version ≥ `minimumHelperVersion`: the app keeps using it (protocol permitting); Settings keeps showing
  `traffic.helper.outdated`, and nothing else reminds the user;
- otherwise (also when `Version` or `Protocol` is missing or unreadable, or a `hello` reports a helper older than
  `minimumHelperVersion`) the app stops the service once (it holds `SERVICE_STOP`), never starts it again, and
  per-process traffic is unavailable (`helperOutdated`; the dashboard's network section shows
  `traffic.unavailable.helperOutdated` with `traffic.helper.update`) until the user updates or removes it. A `hello`
  whose protocol range does not overlap the app's also gives `helperOutdated` (without stopping the service; the app
  checks again every 30 s). The old binary stays on disk (removing it needs administrator approval), but nothing runs
  it: the service is demand-start and only allowed users' apps start it.

The helper changes rarely; its version moves only when its code or protocol changes, so most app updates need no
prompt. `install.ps1` without `-TrafficHelper` never touches an installed helper; with it, it installs or updates
(one prompt).

**Remove** (Settings `traffic.helper.remove` with `traffic.helper.removeConfirm` / `traffic.helper.removeDetail`;
`install.ps1 -Uninstall`; the Apps & Features uninstall entry's `uninstall.ps1`; Settings offers it, and both scripts
elevate, only when this user is in `AllowedUsers`): the elevated helper — a staged copy, never the installed image,
since a running image cannot delete itself — runs `remove --user <SID>` and removes this user from `AllowedUsers`.

- Other users remain: it rewrites `AllowedUsers`, rebuilds the service DACL and stops a running service (≤ 5 s; exit 2
  if it does not stop), because the pipe DACL and the process grant of section 3 are built at service start; the next
  allowed user's app starts it again.
- The list is now empty: it stops the service (≤ 5 s, continuing either way), stops a leftover `AgentSpeed-Traffic`
  session, deletes the service, the registry key (and `HKLM\SOFTWARE\AgentSpeed` when nothing else is in it), the ETW
  session's descriptor (`EventAccessRemove`) and the install folder: the binary, a leftover `.new`, the folder and
  `%ProgramFiles%\Agent Speed` when empty (a file or folder still in use is deleted at the next reboot with
  `MOVEFILE_DELAY_UNTIL_REBOOT`). A redirected (reparse-point) folder is never followed: no file is deleted through a
  redirected `Traffic Helper` folder (only the link itself is removed), and a redirected `Agent Speed` folder is left
  in place and the remove exits 1.

History already recorded is kept (DESIGN 10). `install.ps1 -Purge` additionally deletes the user's data as today.

**Installer changes** (`install.ps1`): new switch `-TrafficHelper`: after the per-user install, it creates a staging
folder as above (same protected DACL), has `AgentSpeed.exe --extract-helper <dir>` write the embedded helper and the
app's own SHA-256 of it (`AgentSpeedTrafficHelper.exe.sha256`; the app checks the written file against it; exit 0 or
1, `<dir>` must be absent or an empty ordinary directory), holds the file open with read sharing only from hashing it
again until the elevated run has exited, and runs the elevated install above through `Process.Start` with the `runas`
verb (the same `ShellExecuteEx` as `Start-Process -Verb RunAs`, but a cancelled prompt is reported as
`ERROR_CANCELLED`), working directory System32.
Localized messages for preparing, the approval note (unknown publisher), waiting, done, cancelled, refused (exit 1) and
failed (with the code); a build without an embedded helper says so; no failure stops the app install, and the script
does not start the service (the app does when it samples). `-Uninstall` removes the helper as described; the generated
`uninstall.ps1` does the same (when the app carries no helper, both run a staged copy of the installed,
administrator-owned binary). The installer itself is never elevated as a whole.

## 6. App behaviour

- Whenever per-process sampling is needed (METRICS 10.10: traffic sampling on and an agent process present) and the
  helper is installed for this user (the service exists and this user is in `AllowedUsers`) and not outdated
  (section 5): `StartService` if stopped (once; the service must be running with its pipe open within 10 s), connect
  and verify (section 4), `hello` (the protocol ranges must overlap and the reported version must be ≥
  `minimumHelperVersion`), then snapshots at the sampling interval. Every new connection, and every response with a
  new `epoch`, starts a new stream (METRICS 10.4). Otherwise — sampling off, or standby without agent processes —
  the app disconnects and re-reads the installation every 30 s (stopping an outdated service, section 5) but never
  starts the service; the service stops itself after 120 s.
- States shown in Settings (DESIGN 10): `notInstalled` (also when this user is not among the allowed users), `idle`
  (installed, not running), `running`, `outdated` (installed version below `bundledHelperVersion`), `error` (with
  the `traffic.unavailable.denied` text when verification failed or access was denied, else the Win32 error text).
  Start and connection failures (`helperStopped`, `helperDenied`, `helperError`, METRICS 10.3) retry after 1, 2, 4 …
  60 s; the delay resets after a successful snapshot, after Settings → retry and after an install or removal.
- Machine totals (METRICS 10.2) never depend on the helper.

## 7. Threat model

| Threat | Mitigation |
| --- | --- |
| **Local privilege escalation through the service binary** (a user replaces the privileged executable) | Lives in Program Files, writable only by administrators; the installer refuses a pre-existing `Agent Speed` or `Traffic Helper` folder that is redirected, not owned by Administrators, TrustedInstaller or SYSTEM, or writable by anyone else, and reads the Program Files path from the registry, not the environment; ImagePath quoted (no unquoted-path hijack); no configuration, plug-in or script is ever loaded from a user-writable location. |
| **DLL search-order / binary planting** | NativeAOT single file; `SetDefaultDllDirectories(System32)` and `/DEPENDENTLOADFLAG:0x800`; no `LoadLibrary` of relative names; no adjacent files. The elevated install step is the same NativeAOT binary, never the .NET single-file app. |
| **Abusing the service as a confused deputy** | The protocol has no write operation and no input other than the request type; the service reads no file, path or registry value named by a client; it never impersonates. |
| **Elevation through the service token** | LocalService, not SYSTEM; privileges stripped to `SeChangeNotifyPrivilege` (no `SeImpersonatePrivilege`, so "potato"-style token abuse has nothing to work with); no network access needed or used. Allowed users get only `PROCESS_QUERY_LIMITED_INFORMATION` on the service process (section 3), for the client's image-path check. |
| **Pipe squatting** (another process creates the pipe first to feed fake data or capture clients) | Before sending anything, clients verify the server PID against the SCM (asked before and after the check) and its image path; clients connect with `SECURITY_IDENTIFICATION`, so a fake server cannot impersonate them. The service creates the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE` and exits if the name is taken (a denial of service only, reported as `helperDenied`). |
| **Information disclosure between users** | Pipe ACL limited to allowed users; snapshots limited to the client's session, and session 0 is refused; the ETW session's own descriptor admits only SYSTEM, Administrators and the service SID, so neither Performance Log Users nor other LocalService or NetworkService processes can consume or stop it (section 1); only PIDs, create times and byte counts leave the service — never addresses, ports, host names, payloads or image names. |
| **Remote access** | `PIPE_REJECT_REMOTE_CLIENTS` and a deny ACE for NETWORK. |
| **Denial of service** (flooding requests or events) | ≤ 4 pipe instances and ≤ 2 per session, ≤ 4 requests per second per connection (8 rejections in a row close it), silent (60 s) or non-reading (5 s) clients dropped, fixed-layout responses (≤ 16 384 entries), bounded process table, bounded ETW buffers (lost events are counted, never queued without limit); a misbehaving client affects only its own connection. Event floods cost ≈ 0.2 µs per event (section 3). |
| **Stale privileged code after updates** | Helper versioned separately; `minimumHelperVersion` stops the app from starting an outdated helper; demand-start, so a declined update leaves a stopped service that nothing starts. |
| **Tampered installer input** (malware already running as the user swaps the staged binary) | Out of scope: such code can show its own elevation prompt. The prompt is the trust boundary. Still, the staging folder admits only this user, SYSTEM and Administrators, the staged file is held open with read sharing only from its last hash check until the elevated run exits, and the elevated helper hashes the bytes it installs. Releases are not Authenticode-signed, so Windows shows the publisher as unknown; `traffic.helper.uacNote` says so before the prompt. Signing (open question) would let the prompt show a verified publisher and would allow silent, signature-checked helper updates. |
| **Orphaned ETW session** after a crash | Stopped at the next start (section 3); a session left running without a consumer only drops events into its bounded buffers. |
| **Uninstall leftovers** | Service, registry key, folder, ETW session and the session GUID's descriptor are removed; files in use are scheduled for deletion at reboot. |

## 8. Tests (definition of done)

- Unit: request validation (every malformed variant → `badRequest`, connection closed), rate limiting, snapshot
  encoding, loopback filter (IPv4, IPv6, mapped), PID ≤ 4, exited-entry retention, table eviction.
- Integration on a test VM: install as a standard user via UAC; verify the service account, privileges (`sc qprivs`),
  SID type (`sc qsidtype`), service DACL (`sc sdshow`), pipe DACL, folder ACL, the session GUID's descriptor; a
  non-allowed user and a NETWORK logon cannot connect; a squatting pipe is rejected by the client; download a known
  file and compare the reported bytes with the file size (± 1 %); kill the service and confirm the orphaned session is cleaned up at the next start;
  update with the app running; remove and confirm nothing is left (service, key, folder, session, session descriptor).
- Performance: the budgets of section 3 with the benchmark of METRICS 10.10.
