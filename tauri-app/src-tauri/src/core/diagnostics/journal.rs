use super::{files,Area,Phase,Event,Configuration};
use std::{collections::HashMap,fs,path::{Path,PathBuf},sync::{mpsc::{sync_channel,SyncSender},OnceLock},time::{Duration,Instant,SystemTime}};

enum Message { Event(Area,Phase,Vec<(String,i64)>,u64), Flush(SyncSender<()>) }
static SENDER:OnceLock<Option<SyncSender<Message>>>=OnceLock::new();

pub(crate) fn record(area:Area,phase:Phase,metrics:&[(&str,i64)]) {
    // Unrelated unit/fixture suites must never emit to the runner's real Home.
    // Journal tests use an explicit isolated root and exercise the same writer.
    if cfg!(any(test,feature="business-store-fixture")){return}
    let sender=SENDER.get_or_init(|| {
        let root=Configuration::production().journal;
        let (tx,rx)=sync_channel::<Message>(128);
        std::thread::Builder::new().name("tokenbar-diagnostics".into()).spawn(move||{
            let mut journal=Journal::new(root);
            while let Ok(message)=rx.recv(){match message {
                Message::Event(a,p,m,at)=>journal.record_at(a,p,&m.iter().map(|(k,v)|(k.as_str(),*v)).collect::<Vec<_>>(),at),
                Message::Flush(done)=>{let _=done.send(());}
            }}
        }).ok().map(|_|tx)
    });
    // Timestamp the observation before queueing, not the later disk write.
    // Otherwise a slow journal could make old backend progress look current.
    if let Some(sender)=sender {let _=sender.try_send(Message::Event(area,phase,metrics.iter().filter(|(k,_)|super::allowed_metric(k)).map(|(k,v)|(k.to_string(),*v)).collect(),super::now_ms()));}
}
pub(crate) fn flush() {
    if let Some(Some(sender))=SENDER.get(){let (tx,rx)=sync_channel(1);if sender.try_send(Message::Flush(tx)).is_ok(){let _=rx.recv_timeout(Duration::from_millis(500));}}
}
pub(super) struct Journal {root:PathBuf,session:String,sequence:u64,written:usize,segment:u64,file:Option<fs::File>,disabled:bool,progress:HashMap<String,Instant>}
impl Journal {
    pub(super) fn new(root:PathBuf)->Self {Self{root,session:uuid::Uuid::new_v4().to_string(),sequence:0,written:0,segment:0,file:None,disabled:false,progress:HashMap::new()}}
    pub(super) fn record(&mut self,area:Area,phase:Phase,metrics:&[(&str,i64)]) {
        self.record_at(area,phase,metrics,super::now_ms());
    }
    pub(super) fn record_at(&mut self,area:Area,phase:Phase,metrics:&[(&str,i64)],observed_at:u64) {
        if self.disabled{return}
        if phase==Phase::Progress {let key=format!("{area:?}");if self.progress.get(&key).is_some_and(|at|at.elapsed()<Duration::from_secs(1)){return}self.progress.insert(key,Instant::now());}
        if self.file.is_none(){
            if files::owned(&self.root).is_err(){self.disabled=true;return}
            prune(&self.root);
            match files::new_log(&self.root.join(format!("events-{}-{}.jsonl",self.session,self.segment))){Ok(f)=>self.file=Some(f),Err(_)=>{self.disabled=true;return}}
        }
        self.sequence+=1;
        let mut event=Event::new(&self.session,self.sequence,area,phase,metrics);
        event.at=observed_at;
        let Ok(mut bytes)=serde_json::to_vec(&event) else{return};bytes.push(b'\n');
        if phase==Phase::Failed{let _=files::create(&self.root.join(format!("failure-{}.json",self.session)),&bytes);}
        if self.written+bytes.len()>256*1024{
            self.file=None;self.segment+=1;self.written=0;prune(&self.root);
            match files::new_log(&self.root.join(format!("events-{}-{}.jsonl",self.session,self.segment))){Ok(f)=>self.file=Some(f),Err(_)=>{self.disabled=true;return}}
        }
        if files::append(self.file.as_mut().unwrap(),&bytes).is_err(){self.disabled=true;self.file=None;return}
        self.written+=bytes.len();
    }
}
fn prune(root:&Path) {
    let Ok(files)=files::list(root) else{return};
    let mut records=Vec::new();
    for file in files {
        let name=file.file_name().unwrap_or_default().to_string_lossy();
        if !(name.starts_with("events-")&&name.ends_with(".jsonl")||name.starts_with("failure-")&&name.ends_with(".json")){continue}
        let Ok(bytes)=files::read(&file,512*1024) else{continue};
        if !bytes.split(|b|*b==b'\n').next().is_some_and(|line|Event::sanitized(line).is_some()){continue}
        let Ok(date)=fs::metadata(&file).and_then(|m|m.modified()) else{continue};
        records.push((file,date,bytes.len()));
    }
    records.sort_by_key(|r|r.1);let mut total:usize=records.iter().map(|r|r.2).sum();let mut count=records.len();
    for (file,date,size) in records {if SystemTime::now().duration_since(date).unwrap_or_default()>Duration::from_secs(30*86400)||total>8*1024*1024||count>120 {
        if fs::remove_file(file).is_ok(){total=total.saturating_sub(size);count=count.saturating_sub(1)}
    }}
}
