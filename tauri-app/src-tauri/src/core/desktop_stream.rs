//! Read-only observer for the Codex Desktop local IPC stream.
//!
//! The decoder deliberately retains only turn/item identities and UTF-16 text lengths from
//! snapshots. Text enters an event only when Desktop reports an accepted append edit. The
//! transport sends initialize, follow/unfollow, and negative discovery replies; it never
//! creates an IPC server or asks Desktop to resume or control a turn.

use serde::de::{MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_INTERESTS: usize = 4;
const MAX_TRACKED_TURNS: usize = 8;
const MAX_TRACKED_ITEMS: usize = 512;
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_PROJECTED_FRAME_BYTES: usize = 256 * 1024 * 1024;
const MAX_DELTA_BYTES: usize = 1024 * 1024;
const EVENT_QUEUE_CAPACITY: usize = 64;
const READ_CHUNK_BYTES: usize = 64 * 1024;
const FOLLOW_RETRY_DELAYS: [Duration; 4] = [
    Duration::from_secs(10),
    Duration::from_secs(20),
    Duration::from_secs(40),
    Duration::from_secs(60),
];
const CONNECTED_VERIFYING_STATUS: &str = "Desktop 接口已连接，正在核验会话流订阅";
const EMPTY_INTERESTS_STATUS: &str = "Desktop 接口已连接，等待活跃会话";
const MISSING_BASELINE_STATUS: &str =
    "Desktop 接口已连接，但未收到会话状态；正在重试订阅，暂不能测速";

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
    utf16_length: Option<usize>,
    completed: bool,
    observed_creation: bool,
    start_emitted: bool,
}

#[derive(Clone, Debug)]
struct TrackedTurn {
    id: String,
    status: String,
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

    /// Drop only baselines whose owner has disconnected.
    pub fn reset_owner(&mut self, owner: &str, at: f64) -> Vec<DesktopStreamEvent> {
        let mut thread_ids = self
            .threads
            .iter()
            .filter_map(|(thread_id, thread)| (thread.owner == owner).then_some(thread_id.clone()))
            .collect::<Vec<_>>();
        thread_ids.sort();
        for thread_id in &thread_ids {
            self.threads.remove(thread_id);
        }
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

        // Keep a bounded shadow for pending turns too: Desktop can publish an entity before it
        // assigns a turn ID or changes its status to inProgress.
        if let Some(entities) = state
            .pointer("/turnHistory/history/entitiesByKey")
            .and_then(Value::as_object)
        {
            for (key, value) in entities {
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
                if matches!(
                    patch.get("op").and_then(Value::as_str),
                    Some("move" | "copy")
                ) {
                    self.resubscribe = Some(thread_id.to_owned());
                    return vec![DesktopStreamEvent::reset(thread_id, at)];
                }
                let Some(path) = patch.get("path").and_then(Value::as_array) else {
                    continue;
                };
                let Some((key, tail)) = patch_location(path) else {
                    continue;
                };
                if tail.is_empty() {
                    if patch.get("op").and_then(Value::as_str) == Some("remove") {
                        if let Some(removed) = thread.turns.remove(&key) {
                            if removed.status == "inProgress"
                                && !removed.id.is_empty()
                                && !ended_turns.contains(&key)
                            {
                                self.resubscribe = Some(thread_id.to_owned());
                                return vec![DesktopStreamEvent::reset(thread_id, at)];
                            }
                        }
                        continue;
                    }
                    if let Some(value) = patch.get("value") {
                        let replacement_status = value.get("status").and_then(Value::as_str);
                        if replacement_status.is_some_and(is_terminal_status)
                            && thread.turns.get(&key).is_some_and(|turn| {
                                turn.status == "inProgress" && !turn.id.is_empty()
                            })
                        {
                            self.resubscribe = Some(thread_id.to_owned());
                            return vec![DesktopStreamEvent::reset(thread_id, at)];
                        }
                        if let Some(old) = thread.turns.remove(&key) {
                            if !old.id.is_empty() {
                                endings.push(DesktopStreamEvent::reset(thread_id, at));
                            }
                        }
                        if let Some(turn) = parse_turn(value) {
                            if thread.turns.len() >= MAX_TRACKED_TURNS {
                                self.threads.remove(thread_id);
                                self.resubscribe = Some(thread_id.to_owned());
                                return vec![DesktopStreamEvent::reset(thread_id, at)];
                            }
                            thread.turns.insert(key, turn);
                        }
                    }
                    if patch.get("op").and_then(Value::as_str) == Some("move") {
                        self.resubscribe = Some(thread_id.to_owned());
                        return vec![DesktopStreamEvent::reset(thread_id, at)];
                    }
                    continue;
                }

                if !thread.turns.contains_key(&key) {
                    let is_turn_field = matches!(
                        tail.first().and_then(Value::as_str),
                        Some("status" | "turnId" | "params" | "items")
                    );
                    if !is_turn_field {
                        continue;
                    }
                    if thread.turns.len() >= MAX_TRACKED_TURNS {
                        self.resubscribe = Some(thread_id.to_owned());
                        return vec![DesktopStreamEvent::reset(thread_id, at)];
                    }
                    thread.turns.insert(
                        key.clone(),
                        TrackedTurn {
                            id: String::new(),
                            status: "pending".to_owned(),
                            model: "unknown".to_owned(),
                            items: BTreeMap::new(),
                        },
                    );
                }
                let Some(turn) = thread.turns.get_mut(&key) else {
                    continue;
                };
                let was_live = turn.status == "inProgress" && !turn.id.is_empty();
                if tail.len() == 1 && tail[0].as_str() == Some("turnId") {
                    if let Some(id) = patch.get("value").and_then(Value::as_str) {
                        if was_live && !id.is_empty() && id != turn.id {
                            self.resubscribe = Some(thread_id.to_owned());
                            return vec![DesktopStreamEvent::reset(thread_id, at)];
                        }
                        turn.id = id.to_owned();
                    }
                }
                if tail.len() == 1 && tail[0].as_str() == Some("params") {
                    if let Some(model) = patch.pointer("/value/model").and_then(Value::as_str) {
                        turn.model = model.to_owned();
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
                if tail.len() == 1 && tail[0].as_str() == Some("items") {
                    if let Some(values) = patch.get("value").and_then(Value::as_array) {
                        if values.len() > MAX_TRACKED_ITEMS {
                            self.resubscribe = Some(thread_id.to_owned());
                            return vec![DesktopStreamEvent::reset(thread_id, at)];
                        }
                        turn.items.clear();
                        for (index, value) in values.iter().enumerate() {
                            if let Some(item) = parse_item(value, false) {
                                turn.items.insert(index, item);
                            }
                        }
                    }
                }
                if tail.len() == 2 && tail[0].as_str() == Some("items") {
                    if let Some(index) = tail[1].as_u64().and_then(|n| usize::try_from(n).ok()) {
                        if patch.get("op").and_then(Value::as_str) == Some("remove") {
                            if turn.status == "inProgress" && !turn.id.is_empty() {
                                endings.push(DesktopStreamEvent::reset(thread_id, at));
                            }
                            turn.items.clear();
                        } else if let Some(value) = patch.get("value") {
                            if let Some(item) = parse_item(value, false) {
                                let fresh = !turn.items.contains_key(&index);
                                if fresh && turn.items.len() >= MAX_TRACKED_ITEMS {
                                    self.resubscribe = Some(thread_id.to_owned());
                                    return vec![DesktopStreamEvent::reset(thread_id, at)];
                                }
                                let mut item = item;
                                if fresh
                                    && item.item_type == "agentMessage"
                                    && item.utf16_length == Some(0)
                                {
                                    item.observed_creation = true;
                                    if turn.status == "inProgress" && !turn.id.is_empty() {
                                        item.start_emitted = true;
                                        events.push(start_event(
                                            thread_id,
                                            &turn.id,
                                            &turn.model,
                                            &item,
                                            at,
                                        ));
                                    }
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
                            if turn.status == "inProgress" && !turn.id.is_empty() {
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
                }
                if tail.len() == 1 && tail[0].as_str() == Some("status") {
                    if let Some(status) = patch.get("value").and_then(Value::as_str) {
                        turn.status = status.to_owned();
                        if is_terminal_status(status) {
                            if was_live {
                                let kind = if status == "completed" {
                                    DesktopStreamEventKind::Finish
                                } else {
                                    DesktopStreamEventKind::Interrupted
                                };
                                let mut event = DesktopStreamEvent::new(kind, thread_id, at);
                                event.turn_id = Some(turn.id.clone());
                                event.model = turn.model.clone();
                                endings.push(event);
                            }
                            ended_turns.insert(key.clone());
                        }
                    }
                }
                if !was_live && turn.status == "inProgress" && !turn.id.is_empty() {
                    let turn_id = turn.id.clone();
                    let model = turn.model.clone();
                    for item in turn.items.values_mut() {
                        if item.item_type == "agentMessage"
                            && item.observed_creation
                            && !item.completed
                            && !item.start_emitted
                        {
                            item.start_emitted = true;
                            events.push(start_event(thread_id, &turn_id, &model, item, at));
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
                    self.resubscribe = Some(thread_id.to_owned());
                    events.retain(|event| event.kind != DesktopStreamEventKind::Delta);
                    events.extend(endings);
                    events.push(DesktopStreamEvent::reset(thread_id, at));
                    return events;
                };
                let Some(index) = turn
                    .items
                    .iter()
                    .find_map(|(index, item)| (item.id == item_id).then_some(*index))
                else {
                    if turn.status == "inProgress" && !turn.id.is_empty() {
                        self.resubscribe = Some(thread_id.to_owned());
                        events.retain(|event| event.kind != DesktopStreamEventKind::Delta);
                        events.extend(endings);
                        events.push(DesktopStreamEvent::reset(thread_id, at));
                        return events;
                    }
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
                    let Some(offset) = edit
                        .get("at")
                        .and_then(Value::as_u64)
                        .and_then(|offset| usize::try_from(offset).ok())
                    else {
                        valid = false;
                        break;
                    };
                    if item.utf16_length.is_none() {
                        // Large projected snapshots intentionally omit text. The first accepted
                        // edit supplies the pre-insert UTF-16 offset without replaying history.
                        item.utf16_length = Some(offset);
                    }
                    if item.utf16_length != Some(offset)
                        || edit.get("deleteCount").and_then(Value::as_u64) != Some(0)
                        || insert.len() > MAX_DELTA_BYTES
                        || delta.len().saturating_add(insert.len()) > MAX_DELTA_BYTES
                    {
                        valid = false;
                        break;
                    }
                    item.utf16_length = item
                        .utf16_length
                        .and_then(|length| length.checked_add(insert.encode_utf16().count()));
                    if item.utf16_length.is_none() {
                        valid = false;
                        break;
                    }
                    delta.push_str(insert);
                }
                let terminal_same_frame = endings.iter().any(|event| {
                    event.turn_id.as_deref() == Some(turn.id.as_str())
                        && event.item_id.is_none()
                        && (event.kind == DesktopStreamEventKind::Finish
                            || event.kind == DesktopStreamEventKind::Interrupted)
                });
                if valid
                    && !delta.is_empty()
                    && (turn.status == "inProgress" || terminal_same_frame)
                    && !turn.id.is_empty()
                {
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
    let status = value.get("status")?.as_str()?;
    if is_terminal_status(status) {
        return None;
    }
    let id = value
        .get("turnId")
        .and_then(Value::as_str)
        .unwrap_or_default();
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
                let original_index = item_value
                    .get("_tokenbarOriginalIndex")
                    .and_then(Value::as_u64)
                    .and_then(|value| usize::try_from(value).ok())
                    .unwrap_or(index);
                items.insert(original_index, item);
            }
        }
    }
    Some(TrackedTurn {
        id: id.to_owned(),
        status: status.to_owned(),
        model,
        items,
    })
}

fn is_terminal_status(status: &str) -> bool {
    matches!(status, "completed" | "interrupted" | "failed")
}

fn parse_item(value: &Value, completed: bool) -> Option<TrackedItem> {
    let id = value.get("id")?.as_str()?;
    let item_type = value.get("type")?.as_str()?;
    Some(TrackedItem {
        id: id.to_owned(),
        item_type: item_type.to_owned(),
        utf16_length: if value
            .get("_tokenbarUnknownTextLength")
            .and_then(Value::as_bool)
            == Some(true)
        {
            None
        } else {
            Some(
                value
                    .get("text")
                    .and_then(Value::as_str)
                    .map(|text| text.encode_utf16().count())
                    .unwrap_or(0),
            )
        },
        completed,
        observed_creation: false,
        start_emitted: false,
    })
}

const MAX_PROJECTED_STRING_BYTES: usize = 4096;

#[derive(Debug)]
struct BoundedString(String);

impl<'de> Deserialize<'de> for BoundedString {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct StringVisitor;

        impl Visitor<'_> for StringVisitor {
            type Value = BoundedString;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a bounded string")
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if value.len() > MAX_PROJECTED_STRING_BYTES {
                    return Err(E::custom("projected string exceeded its limit"));
                }
                Ok(BoundedString(value.to_owned()))
            }

            fn visit_borrowed_str<E>(self, value: &'_ str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                self.visit_str(value)
            }

            fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if value.len() > MAX_PROJECTED_STRING_BYTES {
                    return Err(E::custom("projected string exceeded its limit"));
                }
                Ok(BoundedString(value))
            }
        }

        deserializer.deserialize_string(StringVisitor)
    }
}

#[derive(Default)]
struct LimitedEntities(Vec<(String, ProjectedTurn)>);

impl<'de> Deserialize<'de> for LimitedEntities {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct EntitiesVisitor;

        impl<'de> Visitor<'de> for EntitiesVisitor {
            type Value = LimitedEntities;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a bounded entity map")
            }

            fn visit_map<M>(self, mut map: M) -> Result<Self::Value, M::Error>
            where
                M: MapAccess<'de>,
            {
                let mut entities = Vec::new();
                while let Some((key, turn)) = map.next_entry::<BoundedString, ProjectedTurn>()? {
                    if turn
                        .status
                        .as_ref()
                        .is_some_and(|status| !is_terminal_status(&status.0))
                    {
                        if entities.len() >= MAX_TRACKED_TURNS {
                            return Err(serde::de::Error::custom(
                                "snapshot exceeded the active turn limit",
                            ));
                        }
                        entities.push((key.0, turn));
                    }
                }
                Ok(LimitedEntities(entities))
            }
        }

        deserializer.deserialize_map(EntitiesVisitor)
    }
}

#[derive(Default)]
struct LimitedItems(Vec<(usize, ProjectedItem)>);

impl<'de> Deserialize<'de> for LimitedItems {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct ItemsVisitor;

        impl<'de> Visitor<'de> for ItemsVisitor {
            type Value = LimitedItems;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an item array")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let mut items = VecDeque::with_capacity(MAX_TRACKED_ITEMS);
                let mut index = 0usize;
                while let Some(item) = sequence.next_element::<ProjectedItem>()? {
                    if item.id.is_some() && item.item_type.is_some() {
                        if items.len() == MAX_TRACKED_ITEMS {
                            items.pop_front();
                        }
                        items.push_back((index, item));
                    }
                    index = index
                        .checked_add(1)
                        .ok_or_else(|| serde::de::Error::custom("snapshot item index overflow"))?;
                }
                Ok(LimitedItems(items.into_iter().collect()))
            }
        }

        deserializer.deserialize_seq(ItemsVisitor)
    }
}

#[derive(Default)]
struct LimitedCompletedIds(Vec<(String, bool)>);

impl<'de> Deserialize<'de> for LimitedCompletedIds {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct CompletedVisitor;

        impl<'de> Visitor<'de> for CompletedVisitor {
            type Value = LimitedCompletedIds;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a completed item map")
            }

            fn visit_map<M>(self, mut map: M) -> Result<Self::Value, M::Error>
            where
                M: MapAccess<'de>,
            {
                let mut completed = VecDeque::with_capacity(MAX_TRACKED_ITEMS);
                while let Some((key, value)) = map.next_entry::<BoundedString, bool>()? {
                    if completed.len() == MAX_TRACKED_ITEMS {
                        completed.pop_front();
                    }
                    completed.push_back((key.0, value));
                }
                Ok(LimitedCompletedIds(completed.into_iter().collect()))
            }
        }

        deserializer.deserialize_map(CompletedVisitor)
    }
}

#[derive(Default)]
struct LimitedTurns(Vec<ProjectedTurn>);

impl<'de> Deserialize<'de> for LimitedTurns {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct TurnsVisitor;

        impl<'de> Visitor<'de> for TurnsVisitor {
            type Value = LimitedTurns;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a turn array")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let mut turns = Vec::new();
                while let Some(turn) = sequence.next_element::<ProjectedTurn>()? {
                    if turn
                        .status
                        .as_ref()
                        .is_some_and(|status| !is_terminal_status(&status.0))
                    {
                        if turns.len() >= MAX_TRACKED_TURNS {
                            return Err(serde::de::Error::custom(
                                "snapshot exceeded the active turn limit",
                            ));
                        }
                        turns.push(turn);
                    }
                }
                Ok(LimitedTurns(turns))
            }
        }

        deserializer.deserialize_seq(TurnsVisitor)
    }
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedItem {
    id: Option<BoundedString>,
    #[serde(rename = "type")]
    item_type: Option<BoundedString>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedModel {
    model: Option<BoundedString>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedTurn {
    #[serde(rename = "turnId")]
    turn_id: Option<BoundedString>,
    status: Option<BoundedString>,
    params: Option<ProjectedModel>,
    items: Option<LimitedItems>,
    #[serde(rename = "completedItemIds")]
    completed_item_ids: Option<LimitedCompletedIds>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedHistory {
    #[serde(rename = "entitiesByKey")]
    entities_by_key: Option<LimitedEntities>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedTurnHistory {
    history: Option<ProjectedHistory>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedConversationState {
    id: Option<BoundedString>,
    #[serde(rename = "turnHistory")]
    turn_history: Option<ProjectedTurnHistory>,
    turns: Option<LimitedTurns>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedChange {
    #[serde(rename = "type")]
    change_type: Option<BoundedString>,
    revision: Option<i64>,
    #[serde(rename = "conversationState")]
    conversation_state: Option<ProjectedConversationState>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedParams {
    #[serde(rename = "hostId")]
    host_id: Option<BoundedString>,
    #[serde(rename = "conversationId")]
    conversation_id: Option<BoundedString>,
    change: Option<ProjectedChange>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedResult {
    #[serde(rename = "clientId")]
    client_id: Option<BoundedString>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct ProjectedEnvelope {
    #[serde(rename = "type")]
    message_type: Option<BoundedString>,
    method: Option<BoundedString>,
    version: Option<i64>,
    #[serde(rename = "sourceClientId")]
    source_client_id: Option<BoundedString>,
    #[serde(rename = "requestId")]
    request_id: Option<BoundedString>,
    #[serde(rename = "resultType")]
    result_type: Option<BoundedString>,
    result: Option<ProjectedResult>,
    params: Option<ProjectedParams>,
}

fn parse_frame(payload: &[u8]) -> Result<Value, ()> {
    parse_frame_with_raw_limit(payload, MAX_FRAME_BYTES)
}

fn parse_frame_with_raw_limit(payload: &[u8], raw_limit: usize) -> Result<Value, ()> {
    if payload.is_empty() || payload.len() > MAX_PROJECTED_FRAME_BYTES {
        return Err(());
    }
    if payload.len() <= raw_limit {
        return serde_json::from_slice(payload).map_err(|_| ());
    }
    parse_projected_snapshot(payload)
}

fn parse_projected_snapshot(payload: &[u8]) -> Result<Value, ()> {
    let envelope: ProjectedEnvelope = serde_json::from_slice(payload).map_err(|_| ())?;
    let message_type = envelope.message_type.map(|value| value.0);
    let method = envelope.method.map(|value| value.0);
    let source_client_id = envelope.source_client_id.map(|value| value.0);
    let mut output = serde_json::Map::new();
    if let Some(value) = message_type.as_deref() {
        output.insert("type".to_owned(), Value::String(value.to_owned()));
    }
    if let Some(value) = method.as_deref() {
        output.insert("method".to_owned(), Value::String(value.to_owned()));
    }
    if let Some(value) = envelope.version {
        output.insert("version".to_owned(), Value::Number(value.into()));
    }
    if let Some(value) = source_client_id {
        output.insert("sourceClientId".to_owned(), Value::String(value));
    }
    if let Some(value) = envelope.request_id.map(|value| value.0) {
        output.insert("requestId".to_owned(), Value::String(value));
    }
    if let Some(value) = envelope.result_type.map(|value| value.0) {
        output.insert("resultType".to_owned(), Value::String(value));
    }
    if let Some(value) = envelope
        .result
        .and_then(|result| result.client_id)
        .map(|value| value.0)
    {
        output.insert("result".to_owned(), serde_json::json!({"clientId": value}));
    }

    let is_target_stream = message_type.as_deref() == Some("broadcast")
        && method.as_deref() == Some("thread-stream-state-changed")
        && envelope.version == Some(11);
    let Some(params) = envelope.params else {
        return Ok(Value::Object(output));
    };
    let host_id = params.host_id.map(|value| value.0);
    let conversation_id = params.conversation_id.map(|value| value.0);
    if !is_target_stream || host_id.as_deref() != Some("local") {
        return Ok(Value::Object(output));
    }
    let conversation_id = conversation_id.ok_or(())?;
    let change = params.change.ok_or(())?;
    if change.change_type.as_ref().map(|value| value.0.as_str()) != Some("snapshot") {
        // Large patches could contain accepted text. Reconnect and resubscribe instead of
        // silently skipping a delta or materializing the whole frame as JSON Values.
        return Err(());
    }
    let revision = change.revision.ok_or(())?;
    let state = change.conversation_state.ok_or(())?;
    if state.id.as_ref().map(|value| value.0.as_str()) != Some(conversation_id.as_str()) {
        return Err(());
    }

    let mut entities = serde_json::Map::new();
    if let Some(history) = state.turn_history.and_then(|history| history.history) {
        if let Some(tracked) = history.entities_by_key {
            for (key, turn) in tracked.0 {
                let value = project_turn(turn)?;
                entities.insert(key, value);
            }
        }
    }
    let mut turns = Vec::new();
    if let Some(legacy) = state.turns {
        for turn in legacy.0 {
            turns.push(project_turn(turn)?);
        }
    }
    let projected_state = serde_json::json!({
        "id": conversation_id,
        "turnHistory": { "history": { "entitiesByKey": entities } },
        "turns": turns,
    });
    let projected_change = serde_json::json!({
        "type": "snapshot",
        "revision": revision,
        "conversationState": projected_state,
    });
    let projected_params = serde_json::json!({
        "hostId": "local",
        "conversationId": projected_state["id"],
        "change": projected_change,
    });
    output.insert("params".to_owned(), projected_params);
    Ok(Value::Object(output))
}

fn project_turn(turn: ProjectedTurn) -> Result<Value, ()> {
    let status = turn.status.map(|value| value.0).ok_or(())?;
    if is_terminal_status(&status) {
        return Err(());
    }
    let items = turn.items.unwrap_or_default();
    let mut item_values = Vec::with_capacity(items.0.len());
    let mut item_ids = HashSet::new();
    for (original_index, item) in items.0 {
        let id = item.id.map(|value| value.0).ok_or(())?;
        let item_type = item.item_type.map(|value| value.0).ok_or(())?;
        item_ids.insert(id.clone());
        item_values.push(serde_json::json!({
            "id": id,
            "type": item_type,
            "_tokenbarUnknownTextLength": true,
            "_tokenbarOriginalIndex": original_index,
        }));
    }
    let mut completed = serde_json::Map::new();
    if let Some(completed_ids) = turn.completed_item_ids {
        for (item_id, is_completed) in completed_ids.0 {
            if is_completed && item_ids.contains(&item_id) {
                completed.insert(item_id, Value::Bool(true));
            }
        }
    }
    Ok(serde_json::json!({
        "turnId": turn.turn_id.map(|value| value.0).unwrap_or_default(),
        "status": status,
        "params": { "model": turn.params.and_then(|params| params.model).map(|value| value.0).unwrap_or_else(|| "unknown".to_owned()) },
        "items": item_values,
        "completedItemIds": completed,
    }))
}

fn start_event(
    thread_id: &str,
    turn_id: &str,
    model: &str,
    item: &TrackedItem,
    at: f64,
) -> DesktopStreamEvent {
    let mut event = DesktopStreamEvent::new(DesktopStreamEventKind::Start, thread_id, at);
    event.turn_id = Some(turn_id.to_owned());
    event.item_id = Some(item.id.clone());
    event.model = model.to_owned();
    event
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

#[derive(Clone, Debug, Eq, PartialEq)]
enum FollowLifecycleAction {
    FollowingStatusRequested {
        thread_id: String,
        requester_id: String,
    },
    ClientStatusChanged {
        client_id: String,
        connected: bool,
        is_self: bool,
    },
    IpcConnectionReset,
}

fn protocol_id(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= MAX_PROJECTED_STRING_BYTES)
}

/// Parse only the versioned local follower-coordination broadcasts this observer understands.
fn parse_follow_lifecycle_action(
    message: &Value,
    interested: &HashSet<String>,
) -> Option<FollowLifecycleAction> {
    if message.get("type").and_then(Value::as_str) != Some("broadcast") {
        return None;
    }
    let params = message.get("params")?.as_object()?;
    match message.get("method").and_then(Value::as_str)? {
        "thread-stream-following-status-requested" => {
            if message.get("version").and_then(Value::as_i64) != Some(1) {
                return None;
            }
            let thread_id = protocol_id(params.get("conversationId"))?;
            if params.get("hostId").and_then(Value::as_str) != Some("local")
                || !interested.contains(thread_id)
            {
                return None;
            }
            Some(FollowLifecycleAction::FollowingStatusRequested {
                thread_id: thread_id.to_owned(),
                requester_id: protocol_id(message.get("sourceClientId"))?.to_owned(),
            })
        }
        "client-status-changed" => {
            // This method predates the explicit version table and remains version 0.
            if message.get("version").and_then(Value::as_i64) != Some(0) {
                return None;
            }
            let source_client_id = protocol_id(message.get("sourceClientId"))?;
            let client_id = protocol_id(params.get("clientId"))?;
            if source_client_id != client_id {
                return None;
            }
            let connected = match params.get("status").and_then(Value::as_str)? {
                "connected" => true,
                "disconnected" => false,
                _ => return None,
            };
            Some(FollowLifecycleAction::ClientStatusChanged {
                client_id: client_id.to_owned(),
                connected,
                is_self: params.get("isSelf").and_then(Value::as_bool) == Some(true),
            })
        }
        "ipc-connection-reset" => {
            protocol_id(message.get("sourceClientId"))?;
            (message.get("version").and_then(Value::as_i64) == Some(1))
                .then_some(FollowLifecycleAction::IpcConnectionReset)
        }
        _ => None,
    }
}

fn follow_message(
    client_id: &str,
    thread_id: &str,
    following: bool,
    target_client_id: Option<&str>,
) -> Value {
    let mut message = serde_json::json!({
        "type": "broadcast",
        "method": "thread-stream-following-changed",
        "sourceClientId": client_id,
        "version": 1,
        "params": {
            "conversationId": thread_id,
            "hostId": "local",
            "following": following
        }
    });
    if let Some(target) = target_client_id {
        message["targetClientIds"] = serde_json::json!([target]);
    }
    message
}

fn verification_status(
    subscribed: &HashSet<String>,
    decoder: &DesktopStreamDecoder,
    retries: &MissingBaselineFollowRetries,
) -> String {
    if subscribed.is_empty() {
        return EMPTY_INTERESTS_STATUS.to_owned();
    }
    let verified = subscribed
        .iter()
        .filter(|thread_id| decoder.threads.contains_key(*thread_id))
        .count();
    if verified == 0 {
        if retries.has_attempted_retry() {
            MISSING_BASELINE_STATUS.to_owned()
        } else {
            CONNECTED_VERIFYING_STATUS.to_owned()
        }
    } else {
        format!(
            "已连接 Codex Desktop · 已核验 {verified}/{} 个会话订阅",
            subscribed.len()
        )
    }
}

fn ipc_connection_reset_events(
    decoder: &mut DesktopStreamDecoder,
    at: f64,
) -> Vec<DesktopStreamEvent> {
    let mut events = decoder.reset_all(at);
    events.push(DesktopStreamEvent::reset("", at));
    events
}

#[derive(Clone, Copy, Debug)]
struct FollowRetryEntry {
    attempts: usize,
    next_at: Option<std::time::Instant>,
}

/// Capped backoff for selected threads that have no accepted snapshot baseline.
#[derive(Default)]
struct MissingBaselineFollowRetries {
    by_thread: HashMap<String, FollowRetryEntry>,
}

impl MissingBaselineFollowRetries {
    fn restart(&mut self, thread_id: &str, now: std::time::Instant) {
        self.by_thread.insert(
            thread_id.to_owned(),
            FollowRetryEntry {
                attempts: 0,
                next_at: Some(now + FOLLOW_RETRY_DELAYS[0]),
            },
        );
    }

    fn has_attempted_retry(&self) -> bool {
        self.by_thread.values().any(|entry| entry.attempts > 0)
    }

    /// Return retries due now, retaining only selected threads that still lack a baseline.
    fn due_missing(
        &mut self,
        subscribed: &HashSet<String>,
        decoder: &DesktopStreamDecoder,
        now: std::time::Instant,
    ) -> Vec<String> {
        let mut missing = subscribed
            .iter()
            .filter(|thread_id| !decoder.threads.contains_key(*thread_id))
            .cloned()
            .collect::<Vec<_>>();
        missing.sort();
        let missing_set = missing.iter().cloned().collect::<HashSet<_>>();
        self.by_thread
            .retain(|thread_id, _| missing_set.contains(thread_id));
        for thread_id in &missing {
            self.by_thread
                .entry(thread_id.clone())
                .or_insert(FollowRetryEntry {
                    attempts: 0,
                    next_at: Some(now + FOLLOW_RETRY_DELAYS[0]),
                });
        }

        let due = missing
            .into_iter()
            .filter(|thread_id| {
                self.by_thread
                    .get(thread_id)
                    .and_then(|entry| entry.next_at)
                    .is_some_and(|next_at| next_at <= now)
            })
            .collect::<Vec<_>>();
        for thread_id in &due {
            if let Some(entry) = self.by_thread.get_mut(thread_id) {
                entry.attempts = entry.attempts.saturating_add(1);
                let delay_index = entry.attempts.min(FOLLOW_RETRY_DELAYS.len() - 1);
                entry.next_at = Some(now + FOLLOW_RETRY_DELAYS[delay_index]);
            }
        }
        due
    }
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

    #[derive(Default)]
    struct FrameReader {
        bytes: Vec<u8>,
    }

    impl FrameReader {
        fn push(&mut self, incoming: &[u8]) {
            if !incoming.is_empty() {
                self.bytes.extend_from_slice(incoming);
            }
        }

        fn next(&mut self) -> Result<Option<Vec<u8>>, ()> {
            if self.bytes.len() < 4 {
                return Ok(None);
            }
            let length = u32::from_le_bytes(self.bytes[..4].try_into().map_err(|_| ())?) as usize;
            if length == 0 || length > MAX_PROJECTED_FRAME_BYTES {
                return Err(());
            }
            if self.bytes.len() < length + 4 {
                return Ok(None);
            }
            // Keep a single allocation for the large payload. Any trailing bytes are at most
            // the current read chunk; move them aside before compacting the frame in place.
            let mut frame = std::mem::take(&mut self.bytes);
            let trailing = frame.split_off(length + 4);
            frame.copy_within(4..length + 4, 0);
            frame.truncate(length);
            self.bytes = trailing;
            Ok(Some(frame))
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
                        CONNECTED_VERIFYING_STATUS,
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
        let mut retries = MissingBaselineFollowRetries::default();
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
                        write_follow(pipe, &client_id, &thread_id, false, None)?;
                        decoder.threads.remove(&thread_id);
                        emit(
                            sender,
                            overflow_notice,
                            DesktopStreamEvent::reset(thread_id.clone(), wall_time()),
                        );
                    }
                    for thread_id in wanted.difference(&subscribed).cloned().collect::<Vec<_>>() {
                        write_follow(pipe, &client_id, &thread_id, true, None)?;
                    }
                    subscribed = wanted;
                    set_subscription_status(
                        last_status,
                        &subscribed,
                        &decoder,
                        &retries,
                        sender,
                        overflow_notice,
                    );
                }

                let due_retries =
                    retries.due_missing(&subscribed, &decoder, std::time::Instant::now());
                for thread_id in due_retries {
                    // A repeated following=true is the protocol request for a fresh snapshot.
                    // Do not toggle false: that would tear down a healthy owner relationship.
                    write_follow(pipe, &client_id, &thread_id, true, None)?;
                }
                set_subscription_status(
                    last_status,
                    &subscribed,
                    &decoder,
                    &retries,
                    sender,
                    overflow_notice,
                );
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
                let payload = match frames.next()? {
                    Some(payload) => payload,
                    None => break,
                };
                let projected = payload.len() > MAX_FRAME_BYTES;
                let message = parse_frame(&payload)?;
                if projected {
                    set_status(
                        last_status,
                        "A large Desktop IPC snapshot was selectively projected within the 256 MiB frame limit.",
                        sender,
                        overflow_notice,
                    );
                }
                if message.get("type").and_then(Value::as_str) == Some("response")
                    && message.get("method").and_then(Value::as_str) == Some("initialize")
                    && message.get("resultType").and_then(Value::as_str) == Some("success")
                {
                    let Some(id) = message.pointer("/result/clientId").and_then(Value::as_str)
                    else {
                        return Err(());
                    };
                    client_id = id.to_owned();
                    initialized = true;
                    connected_at = std::time::Instant::now();
                    wall_anchor = wall_time();
                    set_status(
                        last_status,
                        CONNECTED_VERIFYING_STATUS,
                        sender,
                        overflow_notice,
                    );
                } else if message.get("type").and_then(Value::as_str)
                    == Some("client-discovery-request")
                {
                    let Some(request_id) = message.get("requestId").and_then(Value::as_str) else {
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
                    let at = wall_anchor + connected_at.elapsed().as_secs_f64();
                    if let Some(action) = parse_follow_lifecycle_action(&message, &interests) {
                        match action {
                            FollowLifecycleAction::FollowingStatusRequested {
                                thread_id,
                                requester_id,
                            } => {
                                write_follow(
                                    pipe,
                                    &client_id,
                                    &thread_id,
                                    true,
                                    Some(&requester_id),
                                )?;
                            }
                            FollowLifecycleAction::ClientStatusChanged {
                                client_id: changed_client_id,
                                connected: true,
                                is_self,
                            } => {
                                let target = (!is_self).then_some(changed_client_id.as_str());
                                for thread_id in &subscribed {
                                    write_follow(pipe, &client_id, thread_id, true, target)?;
                                }
                            }
                            FollowLifecycleAction::ClientStatusChanged {
                                client_id: disconnected_client_id,
                                connected: false,
                                ..
                            } => {
                                let resets = decoder.reset_owner(&disconnected_client_id, at);
                                let retry_at = std::time::Instant::now();
                                for reset in &resets {
                                    retries.restart(&reset.thread_id, retry_at);
                                }
                                emit_many(sender, overflow_notice, resets);
                            }
                            FollowLifecycleAction::IpcConnectionReset => {
                                let resets = ipc_connection_reset_events(&mut decoder, at);
                                emit_many(sender, overflow_notice, resets);
                                let retry_at = std::time::Instant::now();
                                for thread_id in &subscribed {
                                    retries.restart(thread_id, retry_at);
                                    write_follow(pipe, &client_id, thread_id, true, None)?;
                                }
                            }
                        }
                        set_subscription_status(
                            last_status,
                            &subscribed,
                            &decoder,
                            &retries,
                            sender,
                            overflow_notice,
                        );
                    } else {
                        let events = decoder.consume(&message, at, &interests);
                        emit_many(sender, overflow_notice, events);
                        if let Some(thread_id) = decoder.resubscribe.take() {
                            // Decoder invalidation asks the current owner to resend its snapshot.
                            write_follow(pipe, &client_id, &thread_id, true, None)?;
                            retries.restart(&thread_id, std::time::Instant::now());
                        }
                        set_subscription_status(
                            last_status,
                            &subscribed,
                            &decoder,
                            &retries,
                            sender,
                            overflow_notice,
                        );
                    }
                }
            }
        }

        for thread_id in subscribed {
            let _ = write_follow(pipe, &client_id, &thread_id, false, None);
        }
        Ok(())
    }

    fn set_subscription_status(
        previous: &mut String,
        subscribed: &HashSet<String>,
        decoder: &DesktopStreamDecoder,
        retries: &MissingBaselineFollowRetries,
        sender: &SyncSender<DesktopStreamEvent>,
        overflow_notice: &AtomicBool,
    ) {
        let status = verification_status(subscribed, decoder, retries);
        set_status(previous, &status, sender, overflow_notice);
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
        target_client_id: Option<&str>,
    ) -> Result<(), ()> {
        write_message(
            pipe,
            &follow_message(client_id, thread_id, following, target_client_id),
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

    fn status_request(source: &str, version: i64, host: &str, thread_id: &str) -> Value {
        json!({
            "type": "broadcast",
            "method": "thread-stream-following-status-requested",
            "sourceClientId": source,
            "version": version,
            "params": { "hostId": host, "conversationId": thread_id }
        })
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
        assert_eq!(item.utf16_length, Some("old answer".encode_utf16().count()));
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
    fn pending_nil_id_turn_hydrates_until_it_can_emit_start_and_delta() {
        let mut decoder = DesktopStreamDecoder::new();
        let mut initial = snapshot("owner-1", 5, "");
        let entity = &mut initial["params"]["change"]["conversationState"]["turnHistory"]
            ["history"]["entitiesByKey"]["entity-1"];
        entity["status"] = Value::String("pending".to_owned());
        entity.as_object_mut().unwrap().remove("turnId");
        entity["items"] = json!([]);
        assert!(decoder.consume(&initial, 10.0, &interested()).is_empty());

        let item_added = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "add",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "items", 0],
                "value": { "id": "item-pending", "type": "agentMessage", "text": "" }
            }]),
            json!([]),
        );
        assert!(decoder.consume(&item_added, 11.0, &interested()).is_empty());

        let status = patches(
            "owner-1",
            7,
            6,
            json!([
                { "op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "status"], "value": "inProgress" },
                { "op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "params", "model"], "value": "gpt-pending" }
            ]),
            json!([]),
        );
        assert!(decoder.consume(&status, 12.0, &interested()).is_empty());

        let id = patches(
            "owner-1",
            8,
            7,
            json!([{
                "op": "replace",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "turnId"],
                "value": "turn-pending"
            }]),
            json!([]),
        );
        let starts = decoder.consume(&id, 13.0, &interested());
        assert_eq!(starts.len(), 1);
        assert_eq!(starts[0].kind, DesktopStreamEventKind::Start);
        assert_eq!(starts[0].turn_id.as_deref(), Some("turn-pending"));
        assert_eq!(starts[0].item_id.as_deref(), Some("item-pending"));
        assert_eq!(starts[0].model, "gpt-pending");

        let delta = patches(
            "owner-1",
            9,
            8,
            json!([]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-pending" },
                "target": { "field": "text" },
                "edits": [{ "at": 0, "deleteCount": 0, "insert": "new output" }]
            }]),
        );
        let events = decoder.consume(&delta, 14.0, &interested());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Delta);
        assert_eq!(events[0].text, "new output");
    }

    #[test]
    fn unknown_accepted_entity_resubscribes_instead_of_dropping_delta() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let frame = patches(
            "owner-1",
            6,
            5,
            json!([]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "new-entity", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": 0, "deleteCount": 0, "insert": "must not be lost" }]
            }]),
        );
        let events = decoder.consume(&frame, 11.0, &interested());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Reset);
        assert_eq!(decoder.resubscribe.as_deref(), Some("thread-1"));
        assert!(!decoder.threads.contains_key("thread-1"));
    }

    #[test]
    fn active_entity_rekey_removal_invalidates_and_resubscribes() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let removal = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "remove",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1"]
            }]),
            json!([]),
        );
        let events = decoder.consume(&removal, 11.0, &interested());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Reset);
        assert_eq!(decoder.resubscribe.as_deref(), Some("thread-1"));
        assert!(!decoder.threads.contains_key("thread-1"));
    }

    #[test]
    fn same_frame_terminal_status_keeps_the_final_accepted_append() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let frame = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "replace",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "status"],
                "value": "completed"
            }]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": 0, "deleteCount": 0, "insert": "final" }]
            }]),
        );
        let events = decoder.consume(&frame, 11.0, &interested());
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Delta);
        assert_eq!(events[0].text, "final");
        assert_eq!(events[1].kind, DesktopStreamEventKind::Finish);
        assert!(!decoder.threads["thread-1"].turns.contains_key("entity-1"));
    }

    #[test]
    fn pending_queue_statuses_remain_shadow_turns() {
        let mut decoder = DesktopStreamDecoder::new();
        let mut initial = snapshot("owner-1", 5, "");
        let entity = &mut initial["params"]["change"]["conversationState"]["turnHistory"]
            ["history"]["entitiesByKey"]["entity-1"];
        entity["status"] = Value::String("queued".to_owned());
        entity.as_object_mut().unwrap().remove("turnId");
        assert!(decoder.consume(&initial, 10.0, &interested()).is_empty());
        assert_eq!(
            decoder.threads["thread-1"].turns["entity-1"].status,
            "queued"
        );

        let waiting = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "replace",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1", "status"],
                "value": "waiting"
            }]),
            json!([]),
        );
        assert!(decoder.consume(&waiting, 11.0, &interested()).is_empty());
        assert_eq!(
            decoder.threads["thread-1"].turns["entity-1"].status,
            "waiting"
        );
    }

    #[test]
    fn full_terminal_entity_replacement_invalidates_old_baseline() {
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, ""), 10.0, &interested());
        let replacement = patches(
            "owner-1",
            6,
            5,
            json!([{
                "op": "replace",
                "path": ["turnHistory", "history", "entitiesByKey", "entity-1"],
                "value": {
                    "turnId": "turn-1",
                    "status": "completed",
                    "params": { "model": "gpt-test" },
                    "items": [{ "id": "item-1", "type": "agentMessage", "text": "" }]
                }
            }]),
            json!([]),
        );
        let events = decoder.consume(&replacement, 11.0, &interested());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Reset);
        assert_eq!(decoder.resubscribe.as_deref(), Some("thread-1"));
        assert!(!decoder.threads.contains_key("thread-1"));
    }

    #[test]
    fn selective_snapshot_projection_discards_text_and_adopts_first_utf16_offset() {
        let text = "old 🐈";
        let payload = serde_json::to_vec(&snapshot("owner-1", 5, text)).unwrap();
        let projected = parse_frame_with_raw_limit(&payload, 0).unwrap();
        let serialized = serde_json::to_string(&projected).unwrap();
        assert!(!serialized.contains(text));
        assert!(!serialized.contains("_tokenbarOriginalText"));

        let mut decoder = DesktopStreamDecoder::new();
        assert!(decoder.consume(&projected, 10.0, &interested()).is_empty());
        assert_eq!(
            decoder.threads["thread-1"].turns["entity-1"].items[&0].utf16_length,
            None
        );
        let offset = text.encode_utf16().count();
        let append = patches(
            "owner-1",
            6,
            5,
            json!([]),
            json!([{
                "type": "text",
                "key": { "hostId": "local", "threadId": "thread-1", "entityKey": "entity-1", "itemId": "item-1" },
                "target": { "field": "text" },
                "edits": [{ "at": offset, "deleteCount": 0, "insert": " 🌱" }]
            }]),
        );
        let events = decoder.consume(&append, 11.0, &interested());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, DesktopStreamEventKind::Delta);
        assert_eq!(events[0].text, " 🌱");
        assert_eq!(
            decoder.threads["thread-1"].turns["entity-1"].items[&0].utf16_length,
            Some(offset + " 🌱".encode_utf16().count())
        );
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

    #[test]
    fn following_status_requests_are_validated_and_target_the_requester() {
        let interested = interested();
        let request = status_request("owner-2", 1, "local", "thread-1");
        assert_eq!(
            parse_follow_lifecycle_action(&request, &interested),
            Some(FollowLifecycleAction::FollowingStatusRequested {
                thread_id: "thread-1".to_owned(),
                requester_id: "owner-2".to_owned(),
            })
        );

        let response = follow_message("observer-1", "thread-1", true, Some("owner-2"));
        assert_eq!(response["version"], 1);
        assert_eq!(response["params"]["following"], true);
        assert_eq!(response["targetClientIds"], json!(["owner-2"]));

        assert!(parse_follow_lifecycle_action(
            &status_request("owner-2", 2, "local", "thread-1"),
            &interested
        )
        .is_none());
        assert!(parse_follow_lifecycle_action(
            &status_request("owner-2", 1, "remote", "thread-1"),
            &interested
        )
        .is_none());
        assert!(parse_follow_lifecycle_action(
            &status_request("owner-2", 1, "local", "thread-2"),
            &interested
        )
        .is_none());
    }

    #[test]
    fn client_status_version_zero_and_connection_reset_version_one_are_validated() {
        let connected = json!({
            "type": "broadcast",
            "method": "client-status-changed",
            "sourceClientId": "new-client",
            "version": 0,
            "params": { "clientId": "new-client", "clientType": "app", "status": "connected" }
        });
        assert_eq!(
            parse_follow_lifecycle_action(&connected, &interested()),
            Some(FollowLifecycleAction::ClientStatusChanged {
                client_id: "new-client".to_owned(),
                connected: true,
                is_self: false,
            })
        );
        let targeted = follow_message("observer-1", "thread-1", true, Some("new-client"));
        assert_eq!(targeted["targetClientIds"], json!(["new-client"]));

        let disconnected = json!({
            "type": "broadcast",
            "method": "client-status-changed",
            "sourceClientId": "owner-1",
            "version": 0,
            "params": { "clientId": "owner-1", "status": "disconnected" }
        });
        assert_eq!(
            parse_follow_lifecycle_action(&disconnected, &interested()),
            Some(FollowLifecycleAction::ClientStatusChanged {
                client_id: "owner-1".to_owned(),
                connected: false,
                is_self: false,
            })
        );

        let reset = json!({
            "type": "broadcast",
            "method": "ipc-connection-reset",
            "sourceClientId": "desktop",
            "version": 1,
            "params": {}
        });
        assert_eq!(
            parse_follow_lifecycle_action(&reset, &interested()),
            Some(FollowLifecycleAction::IpcConnectionReset)
        );

        let mut wrong_version = connected.clone();
        wrong_version["version"] = json!(1);
        assert!(parse_follow_lifecycle_action(&wrong_version, &interested()).is_none());
        let mut missing_source = connected.clone();
        missing_source
            .as_object_mut()
            .unwrap()
            .remove("sourceClientId");
        assert!(parse_follow_lifecycle_action(&missing_source, &interested()).is_none());
        let mut router_rewritten_source = connected;
        router_rewritten_source["sourceClientId"] = json!("router-client");
        assert!(parse_follow_lifecycle_action(&router_rewritten_source, &interested()).is_none());

        let mut missing_reset_source = reset;
        missing_reset_source
            .as_object_mut()
            .unwrap()
            .remove("sourceClientId");
        assert!(parse_follow_lifecycle_action(&missing_reset_source, &interested()).is_none());
    }

    #[test]
    fn owner_disconnect_and_ipc_reset_clear_only_the_expected_baselines() {
        let both = HashSet::from(["thread-1".to_owned(), "thread-2".to_owned()]);
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, "one"), 10.0, &both);
        let mut second = snapshot("owner-2", 7, "two");
        second["params"]["conversationId"] = json!("thread-2");
        second["params"]["change"]["conversationState"]["id"] = json!("thread-2");
        decoder.consume(&second, 10.0, &both);

        let owner_resets = decoder.reset_owner("owner-1", 11.0);
        assert_eq!(owner_resets.len(), 1);
        assert_eq!(owner_resets[0].thread_id, "thread-1");
        assert!(decoder.threads.contains_key("thread-2"));
        let retries = MissingBaselineFollowRetries::default();
        assert_eq!(
            verification_status(&both, &decoder, &retries),
            "已连接 Codex Desktop · 已核验 1/2 个会话订阅"
        );

        let reset_events = ipc_connection_reset_events(&mut decoder, 12.0);
        assert_eq!(reset_events.len(), 2);
        assert!(reset_events.iter().any(|event| {
            event.kind == DesktopStreamEventKind::Reset && event.thread_id.is_empty()
        }));
        assert!(decoder.threads.is_empty());
        let mut retries = MissingBaselineFollowRetries::default();
        let retry_start = std::time::Instant::now();
        assert!(retries.due_missing(&both, &decoder, retry_start).is_empty());
        assert_eq!(
            verification_status(&both, &decoder, &retries),
            CONNECTED_VERIFYING_STATUS
        );
        assert_eq!(
            retries.due_missing(&both, &decoder, retry_start + Duration::from_secs(10)),
            vec!["thread-1", "thread-2"]
        );
        assert_eq!(
            verification_status(&both, &decoder, &retries),
            MISSING_BASELINE_STATUS
        );
    }

    #[test]
    fn follow_retries_only_missing_baselines_with_capped_sixty_second_backoff() {
        let start = std::time::Instant::now();
        let subscribed = HashSet::from(["thread-1".to_owned(), "thread-2".to_owned()]);
        let mut decoder = DesktopStreamDecoder::new();
        decoder.consume(&snapshot("owner-1", 5, "healthy"), 10.0, &subscribed);
        let mut retries = MissingBaselineFollowRetries::default();

        assert!(retries.due_missing(&subscribed, &decoder, start).is_empty());
        assert_eq!(retries.by_thread.len(), 1);
        assert_eq!(
            verification_status(&subscribed, &decoder, &retries),
            "已连接 Codex Desktop · 已核验 1/2 个会话订阅"
        );
        assert!(retries
            .due_missing(&subscribed, &decoder, start + Duration::from_secs(9))
            .is_empty());
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(10)),
            vec!["thread-2"]
        );
        assert_eq!(
            verification_status(&subscribed, &decoder, &retries),
            "已连接 Codex Desktop · 已核验 1/2 个会话订阅"
        );
        assert!(retries
            .due_missing(&subscribed, &decoder, start + Duration::from_secs(29))
            .is_empty());
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(30)),
            vec!["thread-2"]
        );
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(70)),
            vec!["thread-2"]
        );
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(130)),
            vec!["thread-2"]
        );
        assert!(retries
            .due_missing(&subscribed, &decoder, start + Duration::from_secs(189))
            .is_empty());
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(190)),
            vec!["thread-2"]
        );
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(250)),
            vec!["thread-2"]
        );
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(310)),
            vec!["thread-2"]
        );
        assert_eq!(
            retries.due_missing(&subscribed, &decoder, start + Duration::from_secs(10_000)),
            vec!["thread-2"]
        );
        assert!(retries
            .due_missing(
                &subscribed,
                &decoder,
                start + Duration::from_secs(10_000 + 59)
            )
            .is_empty());
        assert_eq!(
            retries.due_missing(
                &subscribed,
                &decoder,
                start + Duration::from_secs(10_000 + 60)
            ),
            vec!["thread-2"]
        );

        let mut new_baseline = snapshot("owner-2", 9, "new baseline");
        new_baseline["params"]["conversationId"] = json!("thread-2");
        new_baseline["params"]["change"]["conversationState"]["id"] = json!("thread-2");
        decoder.consume(&new_baseline, 11.0, &subscribed);
        assert!(retries
            .due_missing(&subscribed, &decoder, start + Duration::from_secs(20_000))
            .is_empty());
        assert!(retries.by_thread.is_empty());
    }
}
