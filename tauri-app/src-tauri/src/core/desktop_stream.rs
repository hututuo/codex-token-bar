//! Read-only observer for the Codex Desktop local IPC stream.
//!
//! The decoder deliberately retains only turn/item identities and UTF-16 text lengths from
//! snapshots. Text enters an event only when Desktop reports an accepted append edit. The
//! transport sends initialize, follow/unfollow, and negative discovery replies; it never
//! creates an IPC server or asks Desktop to resume or control a turn.

use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_INTERESTS: usize = 4;
const MAX_TRACKED_TURNS: usize = 8;
const MAX_TRACKED_ITEMS: usize = 512;
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_DRAIN_BYTES: usize = 256 * 1024 * 1024;
const MAX_DELTA_BYTES: usize = 1024 * 1024;
const EVENT_QUEUE_CAPACITY: usize = 64;
const READ_CHUNK_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopStreamEventKind {
    Status,
    Start,
    Delta,
    Finish,
    Interrupted,
    Reset,
}

/// A small, pollable unit of Desktop stream state or accepted output.
///
/// `thread_id` is empty for process-wide status/reset events. `text` contains accepted append
/// bytes for `Delta`, a human-readable message for `Status`, and is empty for lifecycle events.
#[derive(Clone, Debug, PartialEq)]
pub struct DesktopStreamEvent {
    pub kind: DesktopStreamEventKind,
    pub thread_id: String,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub model: String,
    pub text: String,
    pub at: f64,
}

impl DesktopStreamEvent {
    fn new(kind: DesktopStreamEventKind, thread_id: impl Into<String>, at: f64) -> Self {
        Self {
            kind,
            thread_id: thread_id.into(),
            turn_id: None,
            item_id: None,
            model: "unknown".to_owned(),
            text: String::new(),
            at,
        }
    }

    fn reset(thread_id: impl Into<String>, at: f64) -> Self {
        Self::new(DesktopStreamEventKind::Reset, thread_id, at)
    }

    fn status(message: impl Into<String>, at: f64) -> Self {
        let mut event = Self::new(DesktopStreamEventKind::Status, "", at);
        event.text = message.into();
        event
    }
}

#[derive(Clone, Debug)]
struct TrackedItem {
    id: String,
    item_type: String,
    utf16_length: usize,
    completed: bool,
}

#[derive(Clone, Debug)]
struct TrackedTurn {
    id: String,
    model: String,
    items: BTreeMap<usize, TrackedItem>,
}

#[derive(Clone, Debug)]
struct TrackedThread {
    owner: String,
    revision: i64,
    turns: BTreeMap<String, TrackedTurn>,
}

/// Stateful decoder for version 11 `thread-stream-state-changed` broadcasts.
///
/// Use `resubscribe` after each call. When present, the transport should send one
/// `following:false` and then `following:true` for that thread.
#[derive(Default)]
pub struct DesktopStreamDecoder {
    threads: HashMap<String, TrackedThread>,
    pub resubscribe: Option<String>,
}

impl DesktopStreamDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Consume one decoded JSON IPC message. Snapshot text is never emitted or retained.
    pub fn consume(
        &mut self,
        message: &Value,
        at: f64,
        interests: &HashSet<String>,
    ) -> Vec<DesktopStreamEvent> {
        self.resubscribe = None;
        if message.get("type").and_then(Value::as_str) != Some("broadcast")
            || message.get("method").and_then(Value::as_str) != Some("thread-stream-state-changed")
            || message.get("version").and_then(Value::as_i64) != Some(11)
        {
            return Vec::new();
        }

        let Some(params) = message.get("params") else {
            return Vec::new();
        };
        if params.get("hostId").and_then(Value::as_str) != Some("local") {
            return Vec::new();
        }
        let Some(thread_id) = params.get("conversationId").and_then(Value::as_str) else {
            return Vec::new();
        };
        if !interests.contains(thread_id) {
            return Vec::new();
        }
        let thread_id = thread_id.to_owned();
        let Some(owner) = message.get("sourceClientId").and_then(Value::as_str) else {
            return self.invalidate(&thread_id, at, true);
        };
        let Some(change) = params.get("change") else {
            return self.invalidate(&thread_id, at, true);
        };
        let change_type = change.get("type").and_then(Value::as_str);
        let Some(revision) = change.get("revision").and_then(Value::as_i64) else {
            if matches!(change_type, Some("snapshot" | "patches")) {
                return self.invalidate(&thread_id, at, true);
            }
            return Vec::new();
        };

        match change_type {
            Some("snapshot") => self.consume_snapshot(&thread_id, owner, revision, change, at),
            Some("patches") => self.consume_patches(&thread_id, owner, revision, change, at),
            _ => Vec::new(),
        }
    }

    /// Drop every baseline after a framing or event-queue failure.
    pub fn reset_all(&mut self, at: f64) -> Vec<DesktopStreamEvent> {
        let mut thread_ids = self.threads.keys().cloned().collect::<Vec<_>>();
        thread_ids.sort();
        self.threads.clear();
        thread_ids
            .into_iter()
            .map(|thread_id| DesktopStreamEvent::reset(thread_id, at))
            .collect()
    }

    fn consume_snapshot(
        &mut self,
        thread_id: &str,
        owner: &str,
        revision: i64,
        change: &Value,
        at: f64,
    ) -> Vec<DesktopStreamEvent> {
        let Some(state) = change.get("conversationState") else {
            return self.invalidate(thread_id, at, true);
        };
        if state.get("id").and_then(Value::as_str) != Some(thread_id) {
            return self.invalidate(thread_id, at, true);
        }
        if let Some(previous) = self.threads.get(thread_id) {
            if previous.owner == owner && revision <= previous.revision {
                return Vec::new();
            }
        }

        let mut tracked = TrackedThread {
            owner: owner.to_owned(),
            revision,
            turns: BTreeMap::new(),
        };

        // `turnHistory.history.entitiesByKey` is the current schema. Keep only active turns,
        // and only identities/lengths from their items.
        if let Some(entities) = state
            .pointer("/turnHistory/history/entitiesByKey")
            .and_then(Value::as_object)
        {
            for (key, value) in entities {
                if value.get("status").and_then(Value::as_str) != Some("inProgress") {
                    continue;
                }
                if let Some(turn) = parse_turn(value) {
                    if tracked.turns.len() >= MAX_TRACKED_TURNS {
                        return self.invalidate(thread_id, at, true);
                    }
                    tracked.turns.insert(key.clone(), turn);
                }
            }
        }

        // Keep compatibility with the older array-shaped state observed during rollout.
        if let Some(turns) = state.get("turns").and_then(Value::as_array) {
            for (index, value) in turns.iter().enumerate() {
                if value.get("status").and_then(Value::as_str) != Some("inProgress") {
                    continue;
                }
                if let Some(turn) = parse_turn(value) {
                    if tracked.turns.len() >= MAX_TRACKED_TURNS {
                        return self.invalidate(thread_id, at, true);
                    }
                    tracked.turns.insert(format!("legacy:{index}"), turn);
                }
            }
        }

        let previous = self.threads.insert(thread_id.to_owned(), tracked);
        if previous.is_some() {
            vec![DesktopStreamEvent::reset(thread_id, at)]
        } else {
            Vec::new()
        }
    }

    fn consume_patches(
        &mut self,
        thread_id: &str,
        owner: &str,
        revision: i64,
        change: &Value,
        at: f64,
    ) -> Vec<DesktopStreamEvent> {
        let Some(thread) = self.threads.get(thread_id) else {
            return self.invalidate(thread_id, at, true);
        };
        if owner == thread.owner && revision <= thread.revision {
            return Vec::new();
        }
        if owner != thread.owner
            || change.get("baseRevision").and_then(Value::as_i64) != Some(thread.revision)
            || revision <= thread.revision
        {
            return self.invalidate(thread_id, at, true);
        }

        let Some(mut thread) = self.threads.remove(thread_id) else {
            return self.invalidate(thread_id, at, true);
        };
        let mut events = Vec::new();
        let mut endings = Vec::new();
        let mut ended_turns = HashSet::new();

        if let Some(patches) = change.get("patches").and_then(Value::as_array) {
            for patch in patches {
                let Some(path) = patch.get("path").and_then(Value::as_array) else {
                    continue;
                };
                let Some((key, tail)) = patch_location(path) else {
                    continue;
                };
                if tail.is_empty() {
                    if patch.get("op").and_then(Value::as_str) == Some("remove") {
                        thread.turns.remove(&key);
                        continue;
                    }
                    if let Some(value) = patch.get("value") {
                        if value.get("status").and_then(Value::as_str) == Some("inProgress") {
                            if let Some(turn) = parse_turn(value) {
                                if thread.turns.contains_key(&key) {
                                    endings.push(DesktopStreamEvent::reset(thread_id, at));
                                } else if thread.turns.len() >= MAX_TRACKED_TURNS {
                                    self.threads.remove(thread_id);
                                    self.resubscribe = Some(thread_id.to_owned());
                                    return vec![DesktopStreamEvent::reset(thread_id, at)];
                                }
                                thread.turns.insert(key, turn);
                            }
                        }
                    }
                    continue;
                }

                let Some(turn) = thread.turns.get_mut(&key) else {
                    continue;
                };
                if tail.len() == 1 && tail[0].as_str() == Some("turnId") {
                    if let Some(id) = patch.get("value").and_then(Value::as_str) {
                        turn.id = id.to_owned();
                    }
                }
                if tail.len() == 2
                    && tail[0].as_str() == Some("params")
                    && tail[1].as_str() == Some("model")
                {
                    if let Some(model) = patch.get("value").and_then(Value::as_str) {
                        turn.model = model.to_owned();
                    }
                }
                if tail.len() == 2 && tail[0].as_str() == Some("items") {
                    if let Some(index) = tail[1].as_u64().and_then(|n| usize::try_from(n).ok()) {
                        if patch.get("op").and_then(Value::as_str) == Some("remove") {
                            endings.push(DesktopStreamEvent::reset(thread_id, at));
                            turn.items.clear();
                        } else if let Some(value) = patch.get("value") {
                            if let Some(item) = parse_item(value, false) {
                                let fresh = !turn.items.contains_key(&index);
                                if fresh
                                    && item.item_type == "agentMessage"
                                    && item.utf16_length == 0
                                {
                                    let mut event = DesktopStreamEvent::new(
                                        DesktopStreamEventKind::Start,
                                        thread_id,
                                        at,
                                    );
                                    event.turn_id = Some(turn.id.clone());
                                    event.item_id = Some(item.id.clone());
                                    event.model = turn.model.clone();
                                    events.push(event);
                                }
                                turn.items.insert(index, item);
                            }
                        }
                    }
                }
                if tail.len() == 2 && tail[0].as_str() == Some("completedItemIds") {
                    if let Some(item_id) = tail[1].as_str() {
                        if patch.get("value").and_then(Value::as_bool) == Some(true) {
                            for item in turn.items.values_mut().filter(|item| item.id == item_id) {
                                item.completed = true;
                            }
                            let mut event = DesktopStreamEvent::new(
                                DesktopStreamEventKind::Finish,
                                thread_id,
                                at,
                            );
                            event.turn_id = Some(turn.id.clone());
                            event.item_id = Some(item_id.to_owned());
                            event.model = turn.model.clone();
                            endings.push(event);
                        }
                    }
                }
                if tail.len() == 1 && tail[0].as_str() == Some("status") {
                    if let Some(status) = patch.get("value").and_then(Value::as_str) {
                        if status != "inProgress" {
                            let kind = if status == "completed" {
                                DesktopStreamEventKind::Finish
                            } else {
                                DesktopStreamEventKind::Interrupted
                            };
                            let mut event = DesktopStreamEvent::new(kind, thread_id, at);
                            event.turn_id = Some(turn.id.clone());
                            event.model = turn.model.clone();
                            endings.push(event);
                            ended_turns.insert(key.clone());
                        }
                    }
                }
            }
        }

        if let Some(changes) = change.get("acceptedTextChanges").and_then(Value::as_array) {
            for text_change in changes {
                if text_change.get("type").and_then(Value::as_str) != Some("text") {
                    continue;
                }
                let Some(key) = text_change.get("key") else {
                    continue;
                };
                if key.get("hostId").and_then(Value::as_str) != Some("local")
                    || key.get("threadId").and_then(Value::as_str) != Some(thread_id)
                {
                    continue;
                }
                let (Some(entity_key), Some(item_id)) = (
                    key.get("entityKey").and_then(Value::as_str),
                    key.get("itemId").and_then(Value::as_str),
                ) else {
                    continue;
                };
                let Some(turn) = thread.turns.get_mut(entity_key) else {
                    continue;
                };
                let Some(index) = turn
                    .items
                    .iter()
                    .find_map(|(index, item)| (item.id == item_id).then_some(*index))
                else {
                    continue;
                };
                let Some(item) = turn.items.get_mut(&index) else {
                    continue;
                };
                if item.item_type != "agentMessage"
                    || (item.completed
                        && !endings.iter().any(|event| {
                            event.kind == DesktopStreamEventKind::Finish
                                && event.item_id.as_deref() == Some(item_id)
                        }))
                    || text_change
                        .get("target")
                        .and_then(|target| target.get("field"))
                        .and_then(Value::as_str)
                        != Some("text")
                {
                    continue;
                }
                let Some(edits) = text_change.get("edits").and_then(Value::as_array) else {
                    continue;
                };
                let mut delta = String::new();
                let mut valid = true;
                for edit in edits {
                    let Some(insert) = edit.get("insert").and_then(Value::as_str) else {
                        valid = false;
                        break;
                    };
                    if edit.get("at").and_then(Value::as_u64)
                        != u64::try_from(item.utf16_length).ok()
                        || edit.get("deleteCount").and_then(Value::as_u64) != Some(0)
                        || insert.len() > MAX_DELTA_BYTES
                        || delta.len().saturating_add(insert.len()) > MAX_DELTA_BYTES
                    {
                        valid = false;
                        break;
                    }
                    item.utf16_length += insert.encode_utf16().count();
                    delta.push_str(insert);
                }
                if valid && !delta.is_empty() {
                    let mut event =
                        DesktopStreamEvent::new(DesktopStreamEventKind::Delta, thread_id, at);
                    event.turn_id = Some(turn.id.clone());
                    event.item_id = Some(item.id.clone());
                    event.model = turn.model.clone();
                    event.text = delta;
                    events.push(event);
                } else if !valid {
                    let mut event = DesktopStreamEvent::reset(thread_id, at);
                    event.turn_id = Some(turn.id.clone());
                    event.item_id = Some(item.id.clone());
                    endings.push(event);
                    self.threads.remove(thread_id);
                    self.resubscribe = Some(thread_id.to_owned());
                    events.retain(|event| event.kind != DesktopStreamEventKind::Delta);
                    events.extend(endings);
                    return events;
                }
            }
        }

        for key in ended_turns {
            thread.turns.remove(&key);
        }
        thread.revision = revision;
        if thread.turns.len() > MAX_TRACKED_TURNS {
            self.threads.remove(thread_id);
            self.resubscribe = Some(thread_id.to_owned());
            endings.push(DesktopStreamEvent::reset(thread_id, at));
            events.extend(endings);
            return events;
        }
        self.threads.insert(thread_id.to_owned(), thread);
        events.extend(endings);
        events
    }

    fn invalidate(
        &mut self,
        thread_id: &str,
        at: f64,
        request_resubscribe: bool,
    ) -> Vec<DesktopStreamEvent> {
        let existed = self.threads.remove(thread_id).is_some();
        if request_resubscribe {
            self.resubscribe = Some(thread_id.to_owned());
        }
        if existed || request_resubscribe {
            vec![DesktopStreamEvent::reset(thread_id, at)]
        } else {
            Vec::new()
        }
    }
}

fn parse_turn(value: &Value) -> Option<TrackedTurn> {
    let id = value.get("turnId")?.as_str()?;
    if id.is_empty() {
        return None;
    }
    let model = value
        .pointer("/params/model")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned();
    let completed = value.get("completedItemIds").and_then(Value::as_object);
    let mut items = BTreeMap::new();
    if let Some(values) = value.get("items").and_then(Value::as_array) {
        let start = values.len().saturating_sub(MAX_TRACKED_ITEMS);
        for (index, item_value) in values.iter().enumerate().skip(start) {
            let is_completed = item_value
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| completed.and_then(|map| map.get(id)))
                .and_then(Value::as_bool)
                == Some(true);
            if let Some(item) = parse_item(item_value, is_completed) {
                items.insert(index, item);
            }
        }
    }
    Some(TrackedTurn {
        id: id.to_owned(),
        model,
        items,
    })
}

fn parse_item(value: &Value, completed: bool) -> Option<TrackedItem> {
    let id = value.get("id")?.as_str()?;
    let item_type = value.get("type")?.as_str()?;
    Some(TrackedItem {
        id: id.to_owned(),
        item_type: item_type.to_owned(),
        utf16_length: value
            .get("text")
            .and_then(Value::as_str)
            .map(|text| text.encode_utf16().count())
            .unwrap_or(0),
        completed,
    })
}

fn patch_location(path: &[Value]) -> Option<(String, &[Value])> {
    if path.len() >= 4
        && path[0].as_str() == Some("turnHistory")
        && path[1].as_str() == Some("history")
        && path[2].as_str() == Some("entitiesByKey")
    {
        return Some((path[3].as_str()?.to_owned(), &path[4..]));
    }
    if path.len() >= 2 && path[0].as_str() == Some("turns") {
        let index = path[1].as_u64()?;
        return Some((format!("legacy:{index}"), &path[2..]));
    }
    None
}

fn wall_time() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
}

/// A bounded observer that exposes decoded Desktop events through `try_recv`.
///
/// The Windows build connects to the existing `\\.\pipe\codex-ipc` named pipe. Other
/// platforms keep the decoder available for tests but report that transport is unsupported.
pub struct DesktopStreamObserver {
    interests: Arc<Mutex<Vec<String>>>,
    receiver: Mutex<Receiver<DesktopStreamEvent>>,
    stop: Arc<AtomicBool>,
    overflow_notice: Arc<AtomicBool>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl DesktopStreamObserver {
    pub fn start() -> Self {
        let (sender, receiver) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
        let interests = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let overflow_notice = Arc::new(AtomicBool::new(false));
        let worker_interests = Arc::clone(&interests);
        let worker_stop = Arc::clone(&stop);
        let worker_overflow = Arc::clone(&overflow_notice);
        let worker = thread::Builder::new()
            .name("codex-desktop-stream".to_owned())
            .spawn(move || run_transport(worker_interests, worker_stop, worker_overflow, sender))
            .ok();
        Self {
            interests,
            receiver: Mutex::new(receiver),
            stop,
            overflow_notice,
            worker: Mutex::new(worker),
        }
    }

    /// Replace the followed set. The worker sorts and caps it at four thread IDs.
    pub fn update_threads<I, S>(&self, threads: I)
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut unique = threads.into_iter().map(Into::into).collect::<Vec<_>>();
        unique.sort();
        unique.dedup();
        unique.truncate(MAX_INTERESTS);
        if let Ok(mut current) = self.interests.lock() {
            *current = unique;
        }
    }

    /// Poll one event. A full event queue is surfaced first as a global reset after stale
    /// queued events are discarded, so consumers never continue from a partial sample.
    pub fn try_recv(&self) -> Option<DesktopStreamEvent> {
        let receiver = self.receiver.lock().ok()?;
        if self.overflow_notice.swap(false, Ordering::AcqRel) {
            while receiver.try_recv().is_ok() {}
            return Some(DesktopStreamEvent::reset("", wall_time()));
        }
        match receiver.try_recv() {
            Ok(event) => Some(event),
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => None,
        }
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
        if let Ok(mut worker) = self.worker.lock() {
            if let Some(handle) = worker.take() {
                let _ = handle.join();
            }
        }
    }
}

impl Default for DesktopStreamObserver {
    fn default() -> Self {
        Self::start()
    }
}

impl Drop for DesktopStreamObserver {
    fn drop(&mut self) {
        self.stop();
    }
}

fn emit(
    sender: &SyncSender<DesktopStreamEvent>,
    overflow_notice: &AtomicBool,
    event: DesktopStreamEvent,
) {
    if let Err(TrySendError::Full(_)) = sender.try_send(event) {
        overflow_notice.store(true, Ordering::Release);
    }
}

fn emit_many(
    sender: &SyncSender<DesktopStreamEvent>,
    overflow_notice: &AtomicBool,
    events: impl IntoIterator<Item = DesktopStreamEvent>,
) {
    for event in events {
        emit(sender, overflow_notice, event);
    }
}

fn current_interests(interests: &Mutex<Vec<String>>) -> Vec<String> {
    interests
        .lock()
        .map(|threads| threads.clone())
        .unwrap_or_default()
}

#[cfg(not(windows))]
fn run_transport(
    _interests: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    overflow_notice: Arc<AtomicBool>,
    sender: SyncSender<DesktopStreamEvent>,
) {
    emit(
        &sender,
        &overflow_notice,
        DesktopStreamEvent::status(
            "Codex Desktop IPC transport is available on Windows only.",
            wall_time(),
        ),
    );
    while !stop.load(Ordering::Acquire) {
        thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(windows)]
fn run_transport(
    interests: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    overflow_notice: Arc<AtomicBool>,
    sender: SyncSender<DesktopStreamEvent>,
) {
    windows_transport::run(interests, stop, overflow_notice, sender);
}

#[cfg(windows)]
mod windows_transport {
    use super::*;
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::os::windows::io::AsRawHandle;

    const PIPE_PATH: &str = r"\\.\pipe\codex-ipc";
    const POLL_INTERVAL: Duration = Duration::from_millis(100);

    #[link(name = "kernel32")]
    extern "system" {
        fn PeekNamedPipe(
            pipe: *mut std::ffi::c_void,
            buffer: *mut std::ffi::c_void,
            buffer_size: u32,
            bytes_read: *mut u32,
            total_bytes_available: *mut u32,
            bytes_left_this_message: *mut u32,
        ) -> i32;
    }

    enum Frame {
        Json(Vec<u8>),
        Oversized,
    }

    #[derive(Default)]
    struct FrameReader {
        bytes: Vec<u8>,
        skip_remaining: usize,
    }

    impl FrameReader {
        fn push(&mut self, mut incoming: &[u8]) {
            if self.skip_remaining > 0 {
                let skipped = self.skip_remaining.min(incoming.len());
                self.skip_remaining -= skipped;
                incoming = &incoming[skipped..];
            }
            if !incoming.is_empty() {
                self.bytes.extend_from_slice(incoming);
            }
        }

        fn next(&mut self) -> Result<Option<Frame>, ()> {
            if self.bytes.len() < 4 {
                return Ok(None);
            }
            let length = u32::from_le_bytes(self.bytes[..4].try_into().map_err(|_| ())?) as usize;
            if length == 0 || length > MAX_DRAIN_BYTES {
                return Err(());
            }
            if length > MAX_FRAME_BYTES {
                self.bytes.drain(..4);
                let discarded = length.min(self.bytes.len());
                self.bytes.drain(..discarded);
                self.skip_remaining = length - discarded;
                return Ok(Some(Frame::Oversized));
            }
            if self.bytes.len() < length + 4 {
                return Ok(None);
            }
            let payload = self.bytes[4..length + 4].to_vec();
            self.bytes.drain(..length + 4);
            Ok(Some(Frame::Json(payload)))
        }
    }

    pub(super) fn run(
        interests: Arc<Mutex<Vec<String>>>,
        stop: Arc<AtomicBool>,
        overflow_notice: Arc<AtomicBool>,
        sender: SyncSender<DesktopStreamEvent>,
    ) {
        let mut last_status = String::new();
        while !stop.load(Ordering::Acquire) {
            match OpenOptions::new().read(true).write(true).open(PIPE_PATH) {
                Ok(mut pipe) => {
                    set_status(
                        &mut last_status,
                        "Connected to the existing Codex Desktop IPC pipe; initializing read-only following.",
                        &sender,
                        &overflow_notice,
                    );
                    let result = session(
                        &mut pipe,
                        &interests,
                        &stop,
                        &overflow_notice,
                        &sender,
                        &mut last_status,
                    );
                    let _ = result;
                    emit(&sender, &overflow_notice, DesktopStreamEvent::reset("", wall_time()));
                    if stop.load(Ordering::Acquire) {
                        break;
                    }
                    set_status(
                        &mut last_status,
                        "Codex Desktop IPC connection ended; waiting to reconnect.",
                        &sender,
                        &overflow_notice,
                    );
                }
                Err(_) => set_status(
                    &mut last_status,
                    "Codex Desktop IPC pipe is not ready; waiting for the existing Desktop endpoint.",
                    &sender,
                    &overflow_notice,
                ),
            }
            sleep_interruptibly(&stop, Duration::from_secs(1));
        }
    }

    fn session(
        pipe: &mut File,
        interests: &Mutex<Vec<String>>,
        stop: &AtomicBool,
        overflow_notice: &AtomicBool,
        sender: &SyncSender<DesktopStreamEvent>,
        last_status: &mut String,
    ) -> Result<(), ()> {
        let mut client_id = "initializing-client".to_owned();
        write_message(
            pipe,
            &serde_json::json!({
                "type": "request",
                "requestId": uuid::Uuid::new_v4().to_string(),
                "sourceClientId": client_id,
                "version": 0,
                "method": "initialize",
                "params": { "clientType": "tokenbar-readonly-observer" }
            }),
        )?;

        let mut initialized = false;
        let mut subscribed = HashSet::new();
        let mut decoder = DesktopStreamDecoder::new();
        let mut frames = FrameReader::default();
        let mut read_buffer = vec![0u8; READ_CHUNK_BYTES];
        let mut connected_at = std::time::Instant::now();
        let mut wall_anchor = wall_time() - connected_at.elapsed().as_secs_f64();

        while !stop.load(Ordering::Acquire) {
            if initialized {
                let wanted = current_interests(interests)
                    .into_iter()
                    .take(MAX_INTERESTS)
                    .collect::<HashSet<_>>();
                if wanted != subscribed {
                    for thread_id in subscribed.difference(&wanted).cloned().collect::<Vec<_>>() {
                        write_follow(pipe, &client_id, &thread_id, false)?;
                        decoder.threads.remove(&thread_id);
                        emit(
                            sender,
                            overflow_notice,
                            DesktopStreamEvent::reset(thread_id.clone(), wall_time()),
                        );
                    }
                    for thread_id in wanted.difference(&subscribed).cloned().collect::<Vec<_>>() {
                        write_follow(pipe, &client_id, &thread_id, true)?;
                    }
                    subscribed = wanted;
                }
            }

            let available = peek_available(pipe)?;
            if available == 0 {
                if !initialized && connected_at.elapsed() > Duration::from_secs(5) {
                    return Err(());
                }
                sleep_interruptibly(stop, POLL_INTERVAL);
                continue;
            }

            let count = usize::try_from(available)
                .unwrap_or(usize::MAX)
                .min(read_buffer.len());
            pipe.read_exact(&mut read_buffer[..count]).map_err(|_| ())?;
            frames.push(&read_buffer[..count]);
            loop {
                let frame = match frames.next()? {
                    Some(frame) => frame,
                    None => break,
                };
                match frame {
                    Frame::Oversized => {
                        set_status(
                            last_status,
                            "A Desktop IPC frame exceeded 64 MiB and was drained without parsing.",
                            sender,
                            overflow_notice,
                        );
                    }
                    Frame::Json(payload) => {
                        let message: Value = serde_json::from_slice(&payload).map_err(|_| ())?;
                        if message.get("type").and_then(Value::as_str) == Some("response")
                            && message.get("method").and_then(Value::as_str) == Some("initialize")
                            && message.get("resultType").and_then(Value::as_str) == Some("success")
                        {
                            let Some(id) =
                                message.pointer("/result/clientId").and_then(Value::as_str)
                            else {
                                return Err(());
                            };
                            client_id = id.to_owned();
                            initialized = true;
                            connected_at = std::time::Instant::now();
                            wall_anchor = wall_time();
                            set_status(
                                last_status,
                                "Following selected Codex Desktop threads read-only; waiting for accepted text changes.",
                                sender,
                                overflow_notice,
                            );
                        } else if message.get("type").and_then(Value::as_str)
                            == Some("client-discovery-request")
                        {
                            let Some(request_id) = message.get("requestId").and_then(Value::as_str)
                            else {
                                continue;
                            };
                            write_message(
                                pipe,
                                &serde_json::json!({
                                    "type": "client-discovery-response",
                                    "requestId": request_id,
                                    "response": { "canHandle": false }
                                }),
                            )?;
                        } else if initialized {
                            let interests = subscribed.clone();
                            let events = decoder.consume(
                                &message,
                                wall_anchor + connected_at.elapsed().as_secs_f64(),
                                &interests,
                            );
                            emit_many(sender, overflow_notice, events);
                            if let Some(thread_id) = decoder.resubscribe.take() {
                                write_follow(pipe, &client_id, &thread_id, false)?;
                                write_follow(pipe, &client_id, &thread_id, true)?;
                            }
                        }
                    }
                }
            }
        }

        for thread_id in subscribed {
            let _ = write_follow(pipe, &client_id, &thread_id, false);
        }
        Ok(())
    }

    fn set_status(
        previous: &mut String,
        status: &str,
        sender: &SyncSender<DesktopStreamEvent>,
        overflow_notice: &AtomicBool,
    ) {
        if previous != status {
            *previous = status.to_owned();
            emit(
                sender,
                overflow_notice,
                DesktopStreamEvent::status(status, wall_time()),
            );
        }
    }

    fn write_follow(
        pipe: &mut File,
        client_id: &str,
        thread_id: &str,
        following: bool,
    ) -> Result<(), ()> {
        write_message(
            pipe,
            &serde_json::json!({
                "type": "broadcast",
                "method": "thread-stream-following-changed",
                "sourceClientId": client_id,
                "version": 1,
                "params": {
                    "conversationId": thread_id,
                    "hostId": "local",
                    "following": following
                }
            }),
        )
    }

    fn write_message(pipe: &mut File, message: &Value) -> Result<(), ()> {
        let payload = serde_json::to_vec(message).map_err(|_| ())?;
        if payload.is_empty() || payload.len() > MAX_FRAME_BYTES {
            return Err(());
        }
        let length = u32::try_from(payload.len()).map_err(|_| ())?;
        pipe.write_all(&length.to_le_bytes()).map_err(|_| ())?;
        pipe.write_all(&payload).map_err(|_| ())?;
        Ok(())
    }

    fn peek_available(pipe: &File) -> Result<u32, ()> {
        let mut available = 0u32;
        let result = unsafe {
            PeekNamedPipe(
                pipe.as_raw_handle(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        };
        if result == 0 {
            Err(())
        } else {
            Ok(available)
        }
    }

    fn sleep_interruptibly(stop: &AtomicBool, duration: Duration) {
        let mut elapsed = Duration::ZERO;
        while elapsed < duration && !stop.load(Ordering::Acquire) {
            let step = (duration - elapsed).min(Duration::from_millis(50));
            thread::sleep(step);
            elapsed += step;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn interested() -> HashSet<String> {
        HashSet::from(["thread-1".to_owned()])
    }

    fn snapshot(owner: &str, revision: i64, text: &str) -> Value {
        json!({
            "type": "broadcast",
            "method": "thread-stream-state-changed",
            "version": 11,
            "sourceClientId": owner,
            "params": {
                "hostId": "local",
                "conversationId": "thread-1",
                "change": {
                    "type": "snapshot",
                    "revision": revision,
                    "conversationState": {
                        "id": "thread-1",
                        "turnHistory": { "history": { "entitiesByKey": {
                            "entity-1": {
                                "turnId": "turn-1",
                                "status": "inProgress",
                                "params": { "model": "gpt-test" },
                                "items": [{ "id": "item-1", "type": "agentMessage", "text": text }]
                            }
                        } } }
                    }
                }
            }
        })
    }

    fn patches(owner: &str, revision: i64, base: i64, patch_list: Value, accepted: Value) -> Value {
        json!({
            "type": "broadcast",
            "method": "thread-stream-state-changed",
            "version": 11,
            "sourceClientId": owner,
            "params": {
                "hostId": "local",
                "conversationId": "thread-1",
                "change": {
                    "type": "patches",
                    "revision": revision,
                    "baseRevision": base,
                    "patches": patch_list,
                    "acceptedTextChanges": accepted
                }
            }
        })
    }

    #[test]
    fn snapshot_is_a_baseline_and_never_samples_existing_text() {
        let mut decoder = DesktopStreamDecoder::new();
        assert!(decoder
            .consume(&snapshot("owner-1", 5, "old answer"), 10.0, &interested())
            .is_empty());
        let thread = decoder.threads.get("thread-1").unwrap();
        let item = thread.turns["entity-1"].items.get(&0).unwrap();
        assert_eq!(item.utf16_length, "old answer".encode_utf16().count());
        assert_eq!(item.id, "item-1");
    }

    #[test]
    fn accepted_append_is_attributed_and_tool_stdout_is_ignored() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, "old "), 10.0, &interested());
        let change = json!([{
            "type": "text",
            "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
            "target": { "field": "text" },
            "edits": [{ "at": 4, "deleteCount": 0, "insert": "answer 🐈" }]
        }]);
        let events = decoder.consume(
            &patches("owner-1", 6, 5, json!([]), change),
            11.0,
            &interested(),
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Delta);
        assert_eq!(events[0].thread_id, "thread-1");
        assert_eq!(events[0].turn_id.as_deref(), Some("turn-1"));
        assert_eq!(events[0].item_id.as_deref(), Some("item-1"));
        assert_eq!(events[0].model, "gpt-test");
        assert_eq!(events[0].text, "answer 🐈");

        let mut tool_decoder = DesktopStreamDecoder::new();
        tool_decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let tool_stdout = json!([{
            "type": "text",
            "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-2" },
            "target": { "field": "text" },
            "edits": [{ "at": 0, "deleteCount": 0, "insert": "secret tool output" }]
        }]);
        let events = tool_decoder.consume(
            &patches(
                "owner-1",
                6,
                5,
                json!([{
                    "op": "add",
                    "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "items", 1],
                    "value": { "id": "item-2", "type": "tool", "text": "" }
                }]),
                tool_stdout,
            ),
            11.0,
            &interested(),
        );
        assert!(events
            .iter()
            .all(|event| event.text != "secret tool output"));
        assert!(events
            .iter()
            .all(|event| event.kind != DesktopStreamEventKind::Delta));
    }

    #[test]
    fn duplicate_revisions_are_ignored_and_missing_revision_resubscribes() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let event = patches(
            "owner-1",
            6,
            5,
            json!([]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": 0, "deleteCount": 0, "insert": "x" }]
            }]),
        );
        assert_eq!(decoder.consume(&event, 11.0, &interested()).len(), 1);
        assert!(decoder.consume(&event, 12.0, &interested()).is_empty());
        let mut missing = patches("owner-1", 7, 6, json!([]), json!([]));
        missing["params"]["change"]
            .as_object_mut()
            .unwrap()
            .remove("revision");
        let events = decoder.consume(&missing, 13.0, &interested());
        assert_eq!(events[0].kind, DesktopStreamEventKind::Reset);
        assert_eq!(decoder.resubscribe.as_deref(), Some("thread-1"));
        assert!(!decoder.threads.contains_key("thread-1"));
    }

    #[test]
    fn owner_switch_and_revision_gap_reset_the_partial_baseline() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let switched = patches("owner-2", 6, 5, json!([]), json!([]));
        assert_eq!(
            decoder.consume(&switched, 11.0, &interested())[0].kind,
            DesktopStreamEventKind::Reset
        );
        assert_eq!(decoder.resubscribe.as_deref(), Some("thread-1"));
        decoder.consume(&snapshot("owner-1", 5, ""), 12.0, &interested());
        let gap = patches("owner-1", 8, 7, json!([]), json!([]));
        assert_eq!(
            decoder.consume(&gap, 13.0, &interested())[0].kind,
            DesktopStreamEventKind::Reset
        );
    }

    #[test]
    fn structural_start_and_terminal_status_are_reported() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let added = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "add",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "items", 1],
                "value": { "id": "item-2", "type": "agentMessage", "text": "" }
            }]),
            json!([]),
        );
        let events = decoder.consume(&added, 11.0, &interested());
        assert_eq!(events[0].kind, DesktopStreamEventKind::Start);
        assert_eq!(events[0].item_id.as_deref(), Some("item-2"));
        let finished = patches(
            "owner-1",
            7,
            6,
            json!([{
                "op": "replace",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "status"],
                "value": "completed"
            }]),
            json!([]),
        );
        assert_eq!(
            decoder.consume(&finished, 12.0, &interested())[0].kind,
            DesktopStreamEventKind::Finish
        );
        assert!(decoder.threads["thread-1"].turns.is_empty());
    }

    #[test]
    fn completed_items_ignore_late_appends_but_allow_same_frame_completion_text() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let complete_with_last_text = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "add",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "completedItemIds", "item-1"],
                "value": true
            }]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": 0, "deleteCount": 0, "insert": "final" }]
            }]),
        );
        let events = decoder.consume(&complete_with_last_text, 11.0, &interested());
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Delta);
        assert_eq!(events[0].text, "final");
        assert_eq!(events[1].kind, DesktopStreamEventKind::Finish);

        let late = patches(
            "owner-1",
            7,
            6,
            json!([]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": 5, "deleteCount": 0, "insert": " late" }]
            }]),
        );
        assert!(decoder.consume(&late, 12.0, &interested()).is_empty());
    }

    #[test]
    fn interest_updates_are_sorted_deduplicated_and_bounded() {
        let observer = DesktopStreamObserver::start();
        observer.update_threads(["d", "b", "a", "c", "a", "e"]);
        assert_eq!(
            *observer.interests.lock().unwrap(),
            vec!["a", "b", "c", "d"]
        );
        observer.stop();
    }
}
