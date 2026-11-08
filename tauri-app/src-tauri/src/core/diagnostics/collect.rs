use super::{files,Event,version};
use serde_json::{json,Value};
use std::{collections::BTreeMap,fs,io::{Cursor,Write},path::{Path,PathBuf},process::{Command,Stdio},time::{Duration,Instant}};

pub(crate) const PROBES:[&str;7]=["environment","events","recovery","installation","storage","legacy","crashes"];
#[derive(Clone)]
pub(crate) struct Configuration {pub(crate) home:PathBuf,pub(crate) support:PathBuf,pub(crate) journal:PathBuf}
impl Configuration {
    pub(crate) fn production()->Self{Self::for_home(dirs::home_dir().unwrap_or_else(std::env::temp_dir))}
    pub(crate) fn for_home(home:PathBuf)->Self {
        let current=dirs::home_dir().is_some_and(|h|h==home);
        let support=if cfg!(windows) {
            let base=if current {std::env::var_os("APPDATA").map(PathBuf::from)}else{None};
            base.unwrap_or_else(||home.join("AppData/Roaming")).join("CodexTokenBarTauri")
        }else{home.join("Library/Application Support/CodexTokenBarTauri")};
        let journal=if cfg!(windows) {
            let base=if current {std::env::var_os("LOCALAPPDATA").map(PathBuf::from)}else{None};
            base.unwrap_or_else(||home.join("AppData/Local")).join("CodexTokenBar/diagnostics/v1")
        }else{home.join("Library/Application Support/CodexTokenBar/diagnostics/v1")};
        Self{home,support,journal}
    }
}
pub(super) fn collect(probe:&str,c:&Configuration)->Value {
    match probe {
        "environment"=>json!({"status":"ok","platform":if cfg!(windows){"windows"}else if cfg!(target_os="macos"){"macos"}else{"linux"},
            "architecture":std::env::consts::ARCH,"version":version(env!("CARGO_PKG_VERSION")),
            "processorCount":std::thread::available_parallelism().map(|n|n.get()).unwrap_or(0),"processCount":process_count(),
            "freeBytes":fs2::available_space(&c.home).ok()}),
        "events"|"installation"=>{
            let root=if probe=="events"{c.journal.clone()}else{c.journal.join("installations")};
            let Ok(paths)=files::list(&root) else{return json!({"status":"unavailable"})};
            let mut events=Vec::new();let mut rejected=0;let mut omitted=paths.len().saturating_sub(128);
            for path in paths.into_iter().take(128) {
                let name=path.file_name().unwrap_or_default().to_string_lossy();
                if !(name.starts_with("events-")||name.starts_with("failure-")||name.starts_with("install-")){continue}
                let Ok(data)=files::read(&path,512*1024) else{rejected+=1;continue};
                for line in data.split(|b|*b==b'\n').filter(|s|!s.is_empty()) {
                    if events.len()>=6000{omitted+=1;continue}
                    if let Some(event)=Event::sanitized(line){events.push(event)}else{rejected+=1}
                }
            }
            events.sort_by_key(|e|e.at);
            let mut output=json!({"status":"ok","events":events,"rejected":rejected,"omitted":omitted});
            if probe=="installation" {
                // Existing updater receipts are projected, never copied verbatim.
                let roots=[c.home.join("AppData/Roaming/local.codex.token-bar.tauri"),c.support.clone()];
                let mut receipts=Vec::new();
                for root in roots {
                    if let Ok(data)=files::read(&root.join("update-install-attempt.json"),64*1024) {
                        if let Ok(value)=serde_json::from_slice::<Value>(&data) {
                            let status=value["status"].as_str().filter(|s|["pending","launchFailed","confirmed"].contains(s)).unwrap_or("unknown");
                            receipts.push(json!({"status":status,"sourceVersion":version(value["source_version"].as_str().unwrap_or("")),
                                "targetVersion":version(value["target_version"].as_str().unwrap_or("")),"startedAt":value["started_at"].as_u64()}));
                        }
                    }
                }
                output["updaterReceipts"]=json!(receipts);
            }
            output
        },
        "recovery"=>{
            let root=c.support.join("recovery-diagnostics/v1");
            let Ok(paths)=files::list(&root) else{return json!({"status":"unavailable"})};
            let mut events=Vec::new();
            for path in paths.into_iter().take(64) {
                let name=path.file_name().unwrap_or_default().to_string_lossy();
                if !(name.starts_with("session-")||name=="latest-failure.json"){continue}
                let Ok(data)=files::read(&path,512*1024) else{continue};
                for line in data.split(|b|*b==b'\n') {
                    if events.len()>=3000{break}
                    let Ok(value)=serde_json::from_slice::<Value>(line) else{continue};
                    let row=value.get("event").unwrap_or(&value);
                    let Some(phase)=row["phase"].as_str().filter(|s|["preparing","importing","verifying","activating","ready","failure"].contains(s)) else{continue};
                    let mut event=json!({"phase":phase});
                    for name in ["at","completed","total","retryCount","code"]{if row[name].is_number(){event[name]=row[name].clone();}}
                    events.push(event);
                }
            }
            json!({"status":"ok","events":events})
        },
        "storage"=>{
            let names=["codex-ledger.sqlite","codex-ledger.sqlite-wal","codex-ledger.sqlite-shm","quota-history.sqlite","multi-client-usage.sqlite"];
            let objects:Vec<_>=names.iter().enumerate().map(|(index,name)|{
                match fs::symlink_metadata(c.support.join(name)) {
                    Ok(info)=>json!({"object":index,"present":true,"regular":info.is_file(),"symlink":info.file_type().is_symlink(),"bytes":info.len(),
                        "modifiedAt":info.modified().ok().and_then(|t|t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d|d.as_secs())}),
                    Err(error)=>json!({"object":index,"present":false,"code":error.raw_os_error()}),
                }
            }).collect();
            json!({"status":"ok","objects":objects,"databaseQueriesPerformed":false,"stateSource":"persisted_diagnostic_events","rawLogsIncluded":false})
        },
        "legacy"=>{
            let paths=[c.support.join("performance-trace.log"),c.support.join("startup-trace.log"),
                c.home.join("AppData/Local/CodexTokenBarTauri/startup-trace.log")];
            let mut rows=Vec::new();
            for (index,path) in paths.iter().enumerate(){
                let Ok(bytes)=files::read(path,512*1024) else{continue};
                let text=String::from_utf8_lossy(&bytes);
                for line in text.lines().rev().take(2000){
                    let mut metrics=BTreeMap::new();
                    for part in line.split_whitespace(){if let Some((k,v))=part.split_once('='){
                        if super::allowed_metric(k){if let Ok(n)=v.parse::<i64>(){metrics.insert(k.to_string(),n);}}
                    }}
                    if !metrics.is_empty(){rows.push(json!({"source":index,"metrics":metrics}));}
                }
            }
            json!({"status":if rows.is_empty(){"unavailable"}else{"ok"},"numericRecords":rows,"rawTextExcluded":true})
        },
        "crashes"=>{
            // WER may be disabled or unavailable. Never read dumps or unrelated apps.
            let root=c.home.join("AppData/Local/CrashDumps");let mut reports=Vec::new();
            if let Ok(paths)=files::list(&root){for path in paths.into_iter().take(128){
                let name=path.file_name().unwrap_or_default().to_string_lossy();
                if name.starts_with("codex-token-bar.exe.")&&name.ends_with(".dmp"){
                    if let Ok(info)=fs::symlink_metadata(path){if info.is_file()&&!info.file_type().is_symlink(){reports.push(json!({"present":true,"bytes":info.len()}));}}
                }
            }}
            json!({"status":if reports.is_empty(){"unavailable"}else{"ok"},"reports":reports,"stacksAndMemoryExcluded":true})
        },
        _=>json!({"status":"unavailable"})
    }
}
fn process_count()->Option<u64>{
    #[cfg(windows)] {
        use windows_sys::Win32::{Foundation::{CloseHandle,INVALID_HANDLE_VALUE},System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot,Process32FirstW,Process32NextW,PROCESSENTRY32W,TH32CS_SNAPPROCESS}};
        let handle=unsafe{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)};if handle==INVALID_HANDLE_VALUE{return None}
        let mut entry:PROCESSENTRY32W=unsafe{std::mem::zeroed()};entry.dwSize=std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut found=unsafe{Process32FirstW(handle,&mut entry)};let mut count=0;
        while found!=0 {
            let length=entry.szExeFile.iter().position(|x|*x==0).unwrap_or(entry.szExeFile.len());
            if String::from_utf16_lossy(&entry.szExeFile[..length]).eq_ignore_ascii_case("codex-token-bar.exe"){count+=1;}
            found=unsafe{Process32NextW(handle,&mut entry)};
        }
        unsafe{CloseHandle(handle)};Some(count)
    }
    #[cfg(not(windows))]{None}
}
pub(super) fn archive(probes:&BTreeMap<String,Value>)->Result<Vec<u8>,()> {
    let probes:BTreeMap<String,Value>=probes.iter().map(|(k,v)|(k.clone(),super::privacy::project(v,0))).collect();
    use zip::{ZipWriter,write::SimpleFileOptions,CompressionMethod};
    let mut archive=ZipWriter::new(Cursor::new(Vec::new()));
    let options=SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let mut filenames=Vec::new();let mut total=0;
    for name in PROBES {
        let value=probes.get(name).cloned().unwrap_or(json!({"status":"unavailable"}));
        let bytes=serde_json::to_vec_pretty(&value).map_err(|_|())?;total+=bytes.len();if total>16*1024*1024{return Err(())}
        let file=format!("state/{name}.json");archive.start_file(&file,options).map_err(|_|())?;archive.write_all(&bytes).map_err(|_|())?;filenames.push(file);
        if let Some(events)=value["events"].as_array(){
            let file=format!("events/{name}.jsonl");archive.start_file(&file,options).map_err(|_|())?;
            for row in events{let mut bytes=serde_json::to_vec(row).map_err(|_|())?;bytes.push(b'\n');archive.write_all(&bytes).map_err(|_|())?;}
            filenames.push(file);
        }
    }
    let events=probes.get("events").and_then(|v|v["events"].as_array());
    let last=|area:&str|events.and_then(|rows|rows.iter().rev().find(|r|r["area"]==area)).and_then(|r|r["at"].as_u64()).unwrap_or(0);
    let statuses=PROBES.iter().map(|name|format!("- {name}: {}",probes.get(*name).and_then(|v|v["status"].as_str()).unwrap_or("unavailable"))).collect::<Vec<_>>().join("\n");
    let summary=format!("# Codex Token Bar 诊断包 / Diagnostic bundle\n\nFormat: tokenbar-diagnostics-v1\n\n{statuses}\n\n后端最后推进 / Last backend progress (Unix ms): {}\nUI 最后收到进度 / Last UI progress (Unix ms): {}\n\n0/unavailable 表示证据缺失，不代表正常、空账或数据丢失。\nlaunched 仅代表安装器启动，confirmed 才是目标版本运行确认。\n没有终止记录不等于已经证明崩溃。\n\nOnly fixed-schema events and approved numeric metadata are included.\nNo credentials, conversations, raw paths, database contents, environment or memory dumps.\nNo business database opens, recovery, migration, checkpoints, repairs or network requests.\nTimeout/unavailable probes are incomplete, not a clean bill of health.\n",last("backendProgress"),last("uiProgress"));
    archive.start_file("SUMMARY.md",options).map_err(|_|())?;archive.write_all(summary.as_bytes()).map_err(|_|())?;filenames.push("SUMMARY.md".into());
    let mut latest=BTreeMap::new();
    if let Some(rows)=events{for row in rows{if let Some(area)=row["area"].as_str(){latest.insert(area.to_string(),row.clone());}}}
    archive.start_file("state/latest-observations.json",options).map_err(|_|())?;
    archive.write_all(&serde_json::to_vec_pretty(&latest).map_err(|_|())?).map_err(|_|())?;filenames.push("state/latest-observations.json".into());
    archive.start_file("manifest.json",options).map_err(|_|())?;
    archive.write_all(&serde_json::to_vec(&json!({"schema":1,"privacy":"allowlist-only","databaseOpened":false,"files":filenames})).map_err(|_|())?).map_err(|_|())?;
    Ok(archive.finish().map_err(|_|())?.into_inner())
}
pub(crate) fn export(output:&Path,c:&Configuration,executable:&Path,timeout:Duration)->Result<(),()> {
    if output.exists()||output.starts_with(&c.support)||!output.is_absolute(){return Err(())}
    let temp=std::env::temp_dir().canonicalize().map_err(|_|())?.join(format!("tokenbar-diagnostic-{}",uuid::Uuid::new_v4()));
    fs::create_dir(&temp).map_err(|_|())?;
    struct Cleanup(PathBuf);impl Drop for Cleanup{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    let _cleanup=Cleanup(temp.clone());let mut results=BTreeMap::new();
    for name in PROBES {
        let target=temp.join(format!("{name}.json"));
        let mut command=Command::new(executable);
        command.args(["--diagnostics-probe",name,"--probe-output"]).arg(&target).arg("--diagnostics-home").arg(&c.home);
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)] {use std::os::windows::process::CommandExt;command.creation_flags(0x0800_0000);}
        let outcome=bounded_child(command,timeout);
        let value=if outcome=="ok"{files::read(&target,8*1024*1024).ok().and_then(|d|serde_json::from_slice(&d).ok()).unwrap_or(json!({"status":"unavailable"}))}
            else{json!({"status":outcome})};
        results.insert(name.to_string(),value);
    }
    files::create(output,&archive(&results)?)
}
pub(crate) fn export_in_child(output:&Path,c:&Configuration,executable:&Path)->Result<(),()> {
    let mut command=Command::new(executable);
    command.arg("--export-diagnostics").arg("--output").arg(output).arg("--diagnostics-home").arg(&c.home);
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)] {use std::os::windows::process::CommandExt;command.creation_flags(0x0800_0000);}
    if bounded_child(command,Duration::from_secs(28))=="ok"{Ok(())}else{Err(())}
}
pub(super) fn bounded_child(mut command:Command,timeout:Duration)->&'static str {
    let Ok(mut child)=command.spawn() else{return "unavailable"};let start=Instant::now();
    loop {
        match child.try_wait(){Ok(Some(status))=>return if status.success(){"ok"}else{"failed"},Err(_)=>{let _=child.kill();return "failed"},_=>{}}
        if start.elapsed()>=timeout.min(Duration::from_secs(35)){let _=child.kill();return "timeout"}
        std::thread::sleep(Duration::from_millis(20));
    }
}
pub(crate) fn cli()->Option<i32> {
    let args:Vec<_>=std::env::args_os().collect();
    let has=|flag:&str|args.iter().any(|a|a==flag);
    if !has("--export-diagnostics")&&!has("--diagnostics-probe"){return None}
    let option=|flag:&str|args.iter().position(|a|a==flag).and_then(|i|args.get(i+1)).cloned();
    let config=option("--diagnostics-home").map(|p|Configuration::for_home(p.into())).unwrap_or_else(Configuration::production);
    if let (Some(probe),Some(output))=(option("--diagnostics-probe"),option("--probe-output")) {
        let name=probe.to_string_lossy();if !PROBES.contains(&name.as_ref()){return Some(64)}
        let result=serde_json::to_vec(&collect(&name,&config)).map_err(|_|()).and_then(|d|files::create(Path::new(&output),&d));
        return Some(if result.is_ok(){0}else{1});
    }
    let output=option("--output").map(PathBuf::from).unwrap_or_else(||config.home.join("Downloads").join(format!("TokenBar-Diagnostics-{}.zip",uuid::Uuid::new_v4())));
    let result=std::env::current_exe().map_err(|_|()).and_then(|exe|export(&output,&config,&exe,Duration::from_secs(3)));
    if result.is_ok(){println!("Diagnostics exported: {}",output.display());Some(0)}else{eprintln!("Diagnostics export failed; choose a new writable destination.");Some(1)}
}
