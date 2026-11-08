use super::*;
use serde_json::json;
use std::{collections::BTreeMap,fs,io::{Cursor,Read},process::Command,time::{Duration,Instant}};

#[test]
fn diagnostic_allowlist_drops_secret_baits_and_paths() {
    let raw=json!({"schema":1,"session":uuid::Uuid::new_v4().to_string(),"sequence":1,"at":1,"area":"refresh","phase":"failed",
        "version":"Bearer SECRET","build":"C:\\private\\project","metrics":{"code":5,"password":42},"conversation":"PRIVATE CHAT","attempt":"SECRET"});
    let event=Event::sanitized(&serde_json::to_vec(&raw).unwrap()).unwrap();
    let safe=serde_json::to_string(&event).unwrap();
    for value in ["SECRET","private","password","PRIVATE CHAT"]{assert!(!safe.contains(value));}
    assert_eq!(event.metrics.get("code"),Some(&5));
    assert!(Event::sanitized(br#"{"schema":999}"#).is_none());
    let mut probes=BTreeMap::new();probes.insert("environment".into(),json!({"status":"Bearer SECRET","version":"C:\\private\\chat","password":"SECRET"}));
    let archive=collect::archive(&probes).unwrap();let text=String::from_utf8_lossy(&archive);
    assert!(!text.contains("SECRET")&&!text.contains("private"));
}
#[test]
fn diagnostic_old_updater_receipt_survives_missing_installer_journal() {
    let root=tempfile::tempdir().unwrap();let c=Configuration::for_home(root.path().canonicalize().unwrap());
    fs::create_dir_all(&c.support).unwrap();
    let path=c.support.join("update-install-attempt.json");
    let bytes=serde_json::to_vec(&json!({"status":"launchFailed","source_version":"0.9.10","target_version":"0.9.11",
        "started_at":123,"directory":"C:\\private\\SECRET","detail":"Bearer SECRET PRIVATE CHAT"})).unwrap();
    fs::write(&path,&bytes).unwrap();
    assert!(!c.journal.exists());
    let result=collect::collect("installation",&c);
    assert_eq!(result["status"],"ok");
    assert_eq!(result["updaterReceipts"][0]["status"],"launchFailed");
    assert_eq!(result["updaterReceipts"][0]["targetVersion"],"0.9.11");
    let mut probes=BTreeMap::new();probes.insert("installation".into(),result);
    let archive=collect::archive(&probes).unwrap();let text=String::from_utf8_lossy(&archive);
    assert!(text.contains("launchFailed"));
    for secret in ["SECRET","PRIVATE CHAT","private"]{assert!(!text.contains(secret));}
    assert_eq!(fs::read(path).unwrap(),bytes);assert!(!c.journal.exists());
}
#[test]
fn diagnostic_collection_never_opens_or_changes_business_database() {
    let root=tempfile::tempdir().unwrap();let c=Configuration::for_home(root.path().canonicalize().unwrap());
    fs::create_dir_all(&c.support).unwrap();let db=c.support.join("codex-ledger.sqlite");
    fs::write(&db,b"PRIVATE CHAT Bearer SECRET intentionally not a SQLite file").unwrap();
    let before=fs::read(&db).unwrap();let mut results=BTreeMap::new();
    for name in collect::PROBES{results.insert(name.into(),collect::collect(name,&c));}
    assert_eq!(results["storage"]["databaseQueriesPerformed"],false);
    let bytes=collect::archive(&results).unwrap();
    let mut zip=zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    for i in 0..zip.len(){let mut text=String::new();zip.by_index(i).unwrap().read_to_string(&mut text).unwrap();
        assert!(!text.contains("PRIVATE CHAT")&&!text.contains("SECRET")&&!text.contains(&c.home.to_string_lossy().to_string()));}
    assert_eq!(fs::read(db).unwrap(),before);assert!(!c.journal.exists());
    assert_eq!(fs::read_dir(&c.support).unwrap().count(),1);
}
#[test]
fn diagnostic_collector_ignores_exclusive_sqlite_lock() {
    let root=tempfile::tempdir().unwrap();let c=Configuration::for_home(root.path().canonicalize().unwrap());fs::create_dir_all(&c.support).unwrap();
    let path=c.support.join("codex-ledger.sqlite");let connection=rusqlite::Connection::open(&path).unwrap();
    connection.execute_batch("CREATE TABLE secret(body TEXT);INSERT INTO secret VALUES('PRIVATE CHAT');BEGIN EXCLUSIVE;").unwrap();
    let before=fs::read(&path).unwrap();let names:Vec<_>=fs::read_dir(&c.support).unwrap().map(|e|e.unwrap().file_name()).collect();let at=Instant::now();
    assert_eq!(collect::collect("storage",&c)["databaseQueriesPerformed"],false);assert!(at.elapsed()<Duration::from_secs(1));
    assert_eq!(fs::read(&path).unwrap(),before);assert_eq!(fs::read_dir(&c.support).unwrap().count(),names.len());
    connection.execute_batch("ROLLBACK").unwrap();
}
#[test]
fn diagnostic_progress_timestamp_retains_observation_time_after_queue_delay() {
    let root=tempfile::tempdir().unwrap();let c=Configuration::for_home(root.path().canonicalize().unwrap());
    let mut journal=journal::Journal::new(c.journal.clone());
    let observed=now_ms().saturating_sub(60_000);
    journal.record_at(Area::BackendProgress,Phase::Completed,&[("completed",10)],observed);
    journal.record_at(Area::UiProgress,Phase::Completed,&[("completed",10)],observed+100);
    drop(journal);
    let result=collect::collect("events",&c);
    assert_eq!(result["events"][0]["at"],observed);
    assert_eq!(result["events"][1]["at"],observed+100);
    let mut probes=BTreeMap::new();probes.insert("events".into(),result);
    let bytes=collect::archive(&probes).unwrap();let mut zip=zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    let mut summary=String::new();zip.by_name("SUMMARY.md").unwrap().read_to_string(&mut summary).unwrap();
    assert!(summary.contains(&format!("Last backend progress (Unix ms): {observed}")));
    assert!(summary.contains(&format!("Last UI progress (Unix ms): {}",observed+100)));
}
#[test]
fn diagnostic_restart_retains_prior_failed_session() {
    let root=tempfile::tempdir().unwrap();let path=root.path().canonicalize().unwrap().join("journal");
    let mut a=journal::Journal::new(path.clone());a.record(Area::Startup,Phase::Started,&[]);a.record(Area::Migration,Phase::Failed,&[("code",5)]);
    let before=files::list(&path).unwrap().into_iter().filter(|p|p.extension().is_some_and(|x|x=="jsonl")).next().unwrap();
    let bytes=fs::read(&before).unwrap();drop(a);
    let mut b=journal::Journal::new(path.clone());b.record(Area::Startup,Phase::Ready,&[]);drop(b);
    assert_eq!(fs::read(before).unwrap(),bytes);
    assert_eq!(files::list(&path).unwrap().iter().filter(|p|p.extension().is_some_and(|x|x=="jsonl")).count(),2);
}
#[test]
fn diagnostic_hardlink_and_existing_output_are_rejected() {
    let root=tempfile::tempdir().unwrap();let root=root.path().canonicalize().unwrap();let source=root.join("keep");let hard=root.join("hard");
    fs::write(&source,b"SECRET").unwrap();fs::hard_link(&source,&hard).unwrap();
    assert!(files::read(&hard,1024).is_err());assert!(files::create(&source,b"replace").is_err());assert_eq!(fs::read(&source).unwrap(),b"SECRET");
}
#[test]
fn diagnostic_timeout_is_bounded_and_partial_zip_is_valid() {
    #[cfg(windows)] let mut command=Command::new("powershell.exe");
    #[cfg(windows)] command.args(["-NoProfile","-NonInteractive","-Command","Start-Sleep -Seconds 10"]);
    #[cfg(not(windows))] let mut command=Command::new("/bin/sleep");
    #[cfg(not(windows))] command.arg("10");
    let at=Instant::now();assert_eq!(collect::bounded_child(command,Duration::from_millis(80)),"timeout");assert!(at.elapsed()<Duration::from_secs(2));
    let mut results=BTreeMap::new();results.insert("events".into(),json!({"status":"timeout"}));
    let bytes=collect::archive(&results).unwrap();let mut zip=zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    let mut summary=String::new();zip.by_name("SUMMARY.md").unwrap().read_to_string(&mut summary).unwrap();assert!(summary.contains("timeout"));
}
#[cfg(unix)]
#[test]
fn diagnostic_symlink_and_fifo_do_not_read_or_block() {
    let root=tempfile::tempdir().unwrap();let path=root.path().canonicalize().unwrap();let source=path.join("private");fs::write(&source,b"SECRET").unwrap();
    std::os::unix::fs::symlink(&source,path.join("link")).unwrap();assert!(files::read(&path.join("link"),1024).is_err());
    let fifo=std::ffi::CString::new(path.join("fifo").to_str().unwrap()).unwrap();assert_eq!(unsafe{libc::mkfifo(fifo.as_ptr(),0o600)},0);
    let at=Instant::now();assert!(files::read(&path.join("fifo"),1024).is_err());assert!(at.elapsed()<Duration::from_secs(1));
}
