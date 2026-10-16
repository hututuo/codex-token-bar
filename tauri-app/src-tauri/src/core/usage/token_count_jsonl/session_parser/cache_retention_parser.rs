//! Pure parser for cache-retention evidence. This data is diagnostic only and
//! never participates in token billing.
use super::super::accounting::{AccountingState, Components};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashSet};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

pub(crate) const REVISION: &str = "cache-retention-v7-native-density-1";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Usage {
    pub(crate) ordinal: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) timestamp: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) input: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) cached: Option<i64>,
}

impl Usage {
    pub(crate) fn valid(&self) -> bool {
        matches!((self.input, self.cached), (Some(input), Some(cached)) if input > 0 && cached >= 0 && cached <= input)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Turn {
    pub(crate) id: String,
    #[serde(rename = "stableID")]
    pub(crate) stable_id: bool,
    pub(crate) ordinal: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) root_ordinal: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) started: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) ended: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) marker: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) first: Option<Usage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) last: Option<Usage>,
    pub(crate) models: BTreeSet<String>,
    pub(crate) reasons: BTreeSet<String>,
    pub(crate) inherited_seed_reasons: BTreeSet<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Boundary {
    pub(crate) ordinal: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "childCreated")]
    pub(crate) child_created_milliseconds: Option<u64>,
    #[serde(rename = "mainFork")]
    pub(crate) is_main_fork: bool,
}

impl Boundary {
    fn metadata(&self) -> super::PaginatedSubagentMetadata {
        super::PaginatedSubagentMetadata {
            ordinal: self.ordinal,
            child_created_milliseconds: self.child_created_milliseconds,
            is_main_fork: self.is_main_fork,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Point {
    pub(crate) id: String,
    pub(crate) source_key: String,
    pub(crate) session_key: String,
    pub(crate) model: String,
    pub(crate) gap_microseconds: i64,
    pub(crate) started_at_microseconds: i64,
    pub(crate) previous_input: i64,
    pub(crate) previous_cached: i64,
    pub(crate) input: i64,
    pub(crate) cached: i64,
}

impl Point {
    pub(crate) fn high_reuse(&self) -> bool {
        self.cached >= self.input - self.input / 5
    }

    pub(crate) fn hit_rate(&self) -> f64 {
        self.cached as f64 / self.input as f64
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Pair {
    pub(crate) id: String,
    pub(crate) session_key: String,
    #[serde(rename = "previousID")]
    pub(crate) previous_id: String,
    #[serde(rename = "nextID")]
    pub(crate) next_id: String,
    #[serde(rename = "stableTurnIDs")]
    pub(crate) stable_turn_ids: bool,
    pub(crate) evidence_signature: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) point: Option<Point>,
    pub(crate) reasons: BTreeSet<String>,
}

impl Pair {
    pub(crate) fn eligible(&self) -> bool {
        self.point.is_some() && self.reasons.is_empty()
    }

    pub(crate) fn stable_key(&self) -> Option<String> {
        self.stable_turn_ids
            .then(|| format!("{}:{}:{}", self.session_key, self.previous_id, self.next_id))
    }
}

/// Persisted parser facts contain no prompt, response, or credentials. The
/// nested ownership adapter preserves Swift's camelCase checkpoint shape while
/// delegating all ownership observations to the production `AccountingState`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Parser {
    pub(crate) session_key: String,
    pub(crate) excluded_subagent: bool,
    pub(crate) explicit_subagent: bool,
    pub(crate) metadata_seen: bool,
    pub(crate) source_flags: BTreeSet<String>,
    pub(crate) turns: Vec<Turn>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) current: Option<usize>,
    pub(crate) pending_reasons: BTreeSet<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) orphan_marker: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) cumulative_total: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) mirror: Option<Usage>,
    pub(crate) next_ordinal: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) boundary: Option<Boundary>,
    #[serde(with = "accounting_state_camel_case")]
    pub(crate) ownership: AccountingState,
    pub(crate) legacy_fork: bool,
    pub(crate) replay: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) replay_reference: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) legacy_own_start: Option<i64>,
}

impl Parser {
    pub(crate) fn new(metadata: Option<&super::PaginatedSubagentMetadata>) -> Self {
        Self {
            session_key: String::new(),
            excluded_subagent: false,
            explicit_subagent: false,
            metadata_seen: false,
            source_flags: BTreeSet::new(),
            turns: Vec::new(),
            current: None,
            pending_reasons: BTreeSet::new(),
            orphan_marker: None,
            cumulative_total: None,
            mirror: None,
            next_ordinal: 0,
            boundary: metadata.map(|metadata| Boundary {
                ordinal: metadata.ordinal,
                child_created_milliseconds: metadata.child_created_milliseconds,
                is_main_fork: metadata.is_main_fork,
            }),
            ownership: AccountingState::fresh(),
            legacy_fork: false,
            replay: false,
            replay_reference: None,
            legacy_own_start: None,
        }
    }

    /// Rebind a restored checkpoint to metadata read from the current source.
    /// The boundary is source data, so each resumed scan refreshes it before
    /// consuming newly appended lines.
    pub(crate) fn refresh_boundary(&mut self, metadata: Option<&super::PaginatedSubagentMetadata>) {
        self.boundary = metadata.map(|metadata| Boundary {
            ordinal: metadata.ordinal,
            child_created_milliseconds: metadata.child_created_milliseconds,
            is_main_fork: metadata.is_main_fork,
        });
    }

    pub(crate) fn consume(&mut self, data: &[u8], known_subagents: &HashSet<String>) {
        let ordinal = self.next_ordinal;
        self.next_ordinal = self
            .next_ordinal
            .checked_add(1)
            .expect("cache-retention line ordinal overflow");

        let Ok(root) = serde_json::from_slice::<Value>(data) else {
            self.mark_unparsed_line();
            return;
        };
        let Some(root) = root.as_object() else {
            self.mark_unparsed_line();
            return;
        };
        let Some(kind) = root.get("type").and_then(Value::as_str) else {
            self.mark_unparsed_line();
            return;
        };
        let payload = root.get("payload").and_then(Value::as_object);
        if payload.is_none()
            && matches!(
                kind,
                "event_msg" | "turn_context" | "token_usage_record" | "session_meta"
            )
        {
            self.mark_reason("missing_payload");
        }
        let payload = payload;
        let event_kind = payload
            .and_then(|payload| payload.get("type"))
            .and_then(Value::as_str);
        let timestamp = root.get("timestamp").and_then(parse_time);

        let old_own_start = self.ownership.paginated_own_start_ordinal;
        if self.boundary.is_some()
            && old_own_start.is_none()
            && (kind == "turn_context"
                || (kind == "event_msg" && event_kind == Some("task_started")))
        {
            if let Ok(line) = std::str::from_utf8(data) {
                let metadata = self.boundary.as_ref().map(Boundary::metadata);
                super::observe_paginated_own_turn(line, metadata.as_ref(), &mut self.ownership);
            }
        }
        if old_own_start.is_none() {
            if let Some(own_start) = self.ownership.paginated_own_start_ordinal {
                self.replay = false;
                self.cumulative_total = None;
                if let Some(index) = self
                    .current
                    .filter(|index| self.turns[*index].root_ordinal == Some(own_start))
                {
                    let turn = &mut self.turns[index];
                    for reason in &turn.inherited_seed_reasons {
                        turn.reasons.remove(reason);
                    }
                    if turn.marker.is_some_and(|marker| marker < turn.ordinal) {
                        turn.marker = None;
                    }
                }
                self.pending_reasons.clear();
            }
        }

        let empty_payload = serde_json::Map::new();
        let payload = payload.unwrap_or(&empty_payload);
        if kind == "session_meta" {
            if self.metadata_seen {
                self.source_flags.insert("multiple_session_metadata".into());
            }
            self.metadata_seen = true;
            let id = payload
                .get("id")
                .or_else(|| payload.get("session_id"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            self.session_key = hash(id);
            if id.is_empty() {
                self.source_flags.insert("missing_session_identity".into());
            }
            self.explicit_subagent = is_subagent(payload);
            self.excluded_subagent = self.explicit_subagent || known_subagents.contains(id);
            self.legacy_fork = payload
                .get("forked_from_id")
                .and_then(Value::as_str)
                .is_some_and(|id| !id.is_empty());
            if self.legacy_fork {
                self.replay = true;
                self.replay_reference =
                    timestamp.or_else(|| payload.get("timestamp").and_then(parse_time));
            }
            return;
        }

        if kind == "event_msg" && event_kind == Some("task_started") {
            if let Some(index) = self
                .current
                .filter(|index| self.turns[*index].ended.is_none())
            {
                self.turns[index]
                    .reasons
                    .insert("overlap_or_incomplete".into());
                self.pending_reasons.insert("overlap_or_incomplete".into());
            }
            let raw_id = payload
                .get("turn_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let mut turn = Turn {
                id: hash(raw_id),
                stable_id: uuid::Uuid::parse_str(raw_id).is_ok(),
                ordinal,
                root_ordinal: root.get("ordinal").and_then(Value::as_u64),
                started: payload
                    .get("started_at")
                    .or_else(|| root.get("timestamp"))
                    .and_then(parse_time),
                ended: None,
                marker: self.orphan_marker,
                first: None,
                last: None,
                models: BTreeSet::new(),
                reasons: self.pending_reasons.clone(),
                inherited_seed_reasons: self.pending_reasons.clone(),
            };
            if raw_id.is_empty() || turn.started.is_none() {
                turn.reasons.insert("missing_boundary".into());
            }
            self.turns.push(turn);
            self.current = Some(self.turns.len() - 1);
            self.pending_reasons.clear();
            self.orphan_marker = None;
            self.mirror = None;
            return;
        }

        let user = (kind == "response_item"
            && event_kind == Some("message")
            && payload.get("role").and_then(Value::as_str) == Some("user"))
            || (kind == "event_msg" && event_kind == Some("user_message"));
        if user && self.replay {
            if let (Some(time), Some(reference)) = (timestamp, self.replay_reference) {
                if time
                    .checked_sub(reference)
                    .is_some_and(|delta| delta > 2_000_000)
                {
                    self.replay = false;
                    if self.boundary.is_none() {
                        self.legacy_own_start = Some(
                            self.current
                                .map(|index| self.turns[index].ordinal)
                                .unwrap_or(ordinal),
                        );
                        self.cumulative_total = None;
                    }
                }
            }
        }

        let compacted = kind == "compacted"
            || (kind == "event_msg"
                && matches!(event_kind, Some("context_compacted" | "compaction")));
        if compacted {
            if let Some(index) = self
                .current
                .filter(|index| self.turns[*index].ended.is_none())
            {
                self.turns[index].reasons.insert("compaction".into());
            } else {
                self.pending_reasons.insert("compaction".into());
            }
            self.mirror = None;
            return;
        }

        let active = self
            .current
            .filter(|index| self.turns[*index].ended.is_none());
        let Some(index) = active else {
            if user {
                self.orphan_marker = Some(ordinal);
            }
            if kind == "event_msg" && event_kind == Some("token_count") {
                self.pending_reasons.insert("usage_outside_turn".into());
                self.mirror = None;
            }
            if kind == "event_msg" && event_kind == Some("task_complete") {
                self.pending_reasons.insert(
                    if self.current.is_none() {
                        "orphan_complete"
                    } else {
                        "completion_identity_mismatch"
                    }
                    .into(),
                );
            }
            if kind == "token_usage_record" {
                self.pending_reasons.insert("usage_outside_turn".into());
            }
            if kind == "event_msg" && is_abort_kind(event_kind) {
                self.pending_reasons.insert("aborted".into());
            }
            return;
        };

        if user {
            if self.turns[index].first.is_some() {
                self.turns[index]
                    .reasons
                    .insert("inserted_or_reassigned_user_marker".into());
            }
            self.turns[index].marker = Some(ordinal);
            return;
        }
        if kind == "turn_context" {
            if let Some(id) = payload.get("turn_id").and_then(Value::as_str) {
                if hash(id) != self.turns[index].id {
                    self.turns[index]
                        .reasons
                        .insert("context_turn_mismatch".into());
                }
            }
            if let Some(model) = payload.get("model").and_then(Value::as_str) {
                let model = model.trim();
                if !model.is_empty() {
                    self.turns[index].models.insert(model.to_owned());
                }
            }
            return;
        }
        if kind == "event_msg" && is_abort_kind(event_kind) {
            self.turns[index].reasons.insert("aborted".into());
            return;
        }
        if kind == "token_usage_record" {
            if hash(
                payload
                    .get("turn_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ) != self.turns[index].id
            {
                self.turns[index]
                    .reasons
                    .insert("usage_turn_mismatch".into());
            }
            if self.mirror.is_some() {
                self.turns[index]
                    .reasons
                    .insert("unmatched_usage_mirror".into());
            }
            let usage = payload.get("usage").and_then(Value::as_object);
            self.mirror = Some(Usage {
                ordinal,
                timestamp,
                input: usage.and_then(|value| integer(value.get("input_tokens"))),
                cached: usage.and_then(|value| integer(value.get("cached_input_tokens"))),
            });
            return;
        }
        if kind == "event_msg" && event_kind == Some("token_count") {
            let info = payload.get("info").and_then(Value::as_object);
            let last_usage = info
                .and_then(|value| value.get("last_token_usage"))
                .and_then(Value::as_object);
            let usage = Usage {
                ordinal,
                timestamp,
                input: last_usage.and_then(|value| integer(value.get("input_tokens"))),
                cached: last_usage.and_then(|value| integer(value.get("cached_input_tokens"))),
            };
            if self.turns[index].marker.is_none() {
                self.turns[index]
                    .reasons
                    .insert("missing_user_marker".into());
            }
            if let Some(mirror) = self.mirror.as_ref() {
                if !mirror.valid() || mirror.input != usage.input || mirror.cached != usage.cached {
                    self.turns[index]
                        .reasons
                        .insert("usage_mirror_mismatch".into());
                }
            }
            self.mirror = None;
            if self.turns[index].first.is_none() {
                self.turns[index].first = Some(usage.clone());
            }
            self.turns[index].last = Some(usage);
            if let Some(total) = info
                .and_then(|value| value.get("total_token_usage"))
                .and_then(Value::as_object)
                .and_then(|value| integer(value.get("total_tokens")))
                .filter(|total| *total >= 0)
            {
                if self
                    .cumulative_total
                    .is_some_and(|previous| total < previous)
                {
                    self.turns[index]
                        .reasons
                        .insert("cumulative_rollback".into());
                }
                self.cumulative_total = Some(total);
            }
            if self.replay {
                self.replay_reference = timestamp.or(self.replay_reference);
            }
            return;
        }
        if kind == "event_msg" && event_kind == Some("task_complete") {
            if hash(
                payload
                    .get("turn_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ) != self.turns[index].id
            {
                self.turns[index]
                    .reasons
                    .insert("completion_identity_mismatch".into());
                return;
            }
            if self.mirror.is_some() {
                self.turns[index]
                    .reasons
                    .insert("unmatched_usage_mirror".into());
                self.mirror = None;
            }
            self.turns[index].ended = payload
                .get("completed_at")
                .or_else(|| root.get("timestamp"))
                .and_then(parse_time);
            if self.turns[index].ended.is_none()
                || self.turns[index].started.is_none()
                || self.turns[index]
                    .ended
                    .zip(self.turns[index].started)
                    .is_some_and(|(ended, started)| ended < started)
            {
                self.turns[index]
                    .reasons
                    .insert("invalid_boundary_time".into());
            }
        }
    }

    fn mark_unparsed_line(&mut self) {
        self.mark_reason("evidence_incomplete");
    }

    fn mark_reason(&mut self, reason: &str) {
        if let Some(index) = self
            .current
            .filter(|index| self.turns[*index].ended.is_none())
        {
            self.turns[index].reasons.insert(reason.into());
        } else {
            self.pending_reasons.insert(reason.into());
        }
    }

    pub(crate) fn is_own(&self, turn: &Turn) -> bool {
        if let Some(boundary) = &self.boundary {
            let limit = boundary.ordinal.min(
                self.ownership
                    .paginated_own_start_ordinal
                    .unwrap_or(boundary.ordinal),
            );
            if limit == u64::MAX {
                return false;
            }
            return turn.root_ordinal.is_some_and(|ordinal| ordinal >= limit);
        }
        if self.legacy_fork {
            return self
                .legacy_own_start
                .is_some_and(|own_start| turn.ordinal >= own_start);
        }
        true
    }

    pub(crate) fn pairs(&self, source: &str, generation: &str) -> Vec<Pair> {
        if self.excluded_subagent {
            return Vec::new();
        }
        let mut flags = self.source_flags.clone();
        if !self.metadata_seen {
            flags.insert("missing_source_metadata".into());
        }
        let own_ids: Vec<_> = self
            .turns
            .iter()
            .filter(|turn| self.is_own(turn))
            .map(|turn| turn.id.as_str())
            .collect();
        if own_ids.iter().copied().collect::<HashSet<_>>().len() != own_ids.len() {
            flags.insert("repeated_turn_identity".into());
        }

        self.turns
            .iter()
            .zip(self.turns.iter().skip(1))
            .map(|(previous, next)| {
                let mut reasons = flags.clone();
                reasons.extend(self.turn_reasons(previous));
                reasons.extend(self.turn_reasons(next));
                if previous.models != next.models {
                    reasons.insert("cross_model".into());
                }
                let delta = next
                    .started
                    .zip(previous.ended)
                    .and_then(|(started, ended)| started.checked_sub(ended));
                if delta.map_or(true, |gap| gap < 0) {
                    reasons.insert("negative_or_missing_gap".into());
                }
                if let Some(last) = previous.last.as_ref().filter(|usage| usage.valid()) {
                    if let (Some(input), Some(cached)) = (last.input, last.cached) {
                        if cached < input - input / 5 {
                            reasons.insert("previous_not_high".into());
                        }
                    }
                }

                let id = hash(&format!(
                    "{}:{}:{}:{}:{}:{}",
                    source, generation, previous.ordinal, next.ordinal, previous.id, next.id
                ));
                let model = (next.models.len() == 1).then(|| next.models.first().unwrap().clone());
                let point = delta
                    .filter(|gap| *gap >= 0)
                    .zip(next.started)
                    .zip(model.clone())
                    .zip(previous.last.as_ref().filter(|usage| usage.valid()))
                    .zip(next.first.as_ref().filter(|usage| usage.valid()))
                    .and_then(|((((gap, started), model), previous_usage), next_usage)| {
                        Some(Point {
                            id: id.clone(),
                            source_key: source.to_owned(),
                            session_key: self.session_key.clone(),
                            model,
                            gap_microseconds: gap,
                            started_at_microseconds: started,
                            previous_input: previous_usage.input?,
                            previous_cached: previous_usage.cached?,
                            input: next_usage.input?,
                            cached: next_usage.cached?,
                        })
                    });
                let values = [
                    delta
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                    next.started
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                    model.unwrap_or_else(|| "missing".into()),
                    previous
                        .last
                        .as_ref()
                        .and_then(|usage| usage.input)
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                    previous
                        .last
                        .as_ref()
                        .and_then(|usage| usage.cached)
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                    next.first
                        .as_ref()
                        .and_then(|usage| usage.input)
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                    next.first
                        .as_ref()
                        .and_then(|usage| usage.cached)
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "missing".into()),
                ];
                Pair {
                    id,
                    session_key: self.session_key.clone(),
                    previous_id: previous.id.clone(),
                    next_id: next.id.clone(),
                    stable_turn_ids: previous.stable_id && next.stable_id,
                    evidence_signature: hash(&values.join(":")),
                    point,
                    reasons,
                }
            })
            .collect()
    }

    fn turn_reasons(&self, turn: &Turn) -> BTreeSet<String> {
        let mut reasons = turn.reasons.clone();
        if !self.is_own(turn) {
            reasons.insert("inherited".into());
        }
        if turn.ended.is_none() {
            reasons.insert("pending".into());
        }
        if turn.models.len() != 1 {
            reasons.insert("missing_or_changed_model".into());
        }
        match turn.first.as_ref() {
            None => {
                reasons.insert("usage_unseen".into());
            }
            Some(first) if !first.valid() => {
                reasons.insert("first_usage_invalid".into());
            }
            Some(_) => {}
        }
        if !turn.last.as_ref().is_some_and(Usage::valid) {
            reasons.insert("last_usage_invalid".into());
        }
        for usage in [turn.first.as_ref(), turn.last.as_ref()]
            .into_iter()
            .flatten()
        {
            let Some(time) = usage.timestamp else {
                reasons.insert("usage_outside_boundary_time".into());
                continue;
            };
            let Some(start) = turn.started else {
                reasons.insert("usage_outside_boundary_time".into());
                continue;
            };
            if time < start
                || turn
                    .ended
                    .and_then(|ended| time.checked_sub(ended))
                    .is_some_and(|after| after > 999_999)
            {
                reasons.insert("usage_outside_boundary_time".into());
            }
        }
        reasons
    }

    /// Stable UUID identities and ordinal fallbacks for the storage layer.
    /// The pair of lists retains every owned turn in source order.
    pub(crate) fn own_turn_identities(&self) -> (Vec<String>, Vec<i64>) {
        let mut stable = Vec::new();
        let mut fallback = Vec::new();
        if self.excluded_subagent {
            return (stable, fallback);
        }
        for turn in self.turns.iter().filter(|turn| self.is_own(turn)) {
            if turn.stable_id {
                stable.push(turn.id.clone());
            } else {
                fallback.push(turn.ordinal);
            }
        }
        (stable, fallback)
    }

    pub(crate) fn own_turn_count(&self) -> usize {
        if self.excluded_subagent {
            0
        } else {
            self.turns.iter().filter(|turn| self.is_own(turn)).count()
        }
    }
}

fn is_subagent(payload: &serde_json::Map<String, Value>) -> bool {
    payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
        || payload
            .get("source")
            .and_then(Value::as_object)
            .is_some_and(|source| source.contains_key("subagent"))
        || payload
            .get("agent_role")
            .and_then(Value::as_str)
            .is_some_and(|role| !role.is_empty())
        || payload
            .get("agent_path")
            .and_then(Value::as_str)
            .is_some_and(|path| !path.is_empty())
}

fn is_abort_kind(event_kind: Option<&str>) -> bool {
    matches!(event_kind, Some("turn_aborted" | "task_aborted"))
}

fn integer(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    number
        .as_i64()
        .or_else(|| number.as_u64().and_then(|value| i64::try_from(value).ok()))
}

fn parse_time(value: &Value) -> Option<i64> {
    if let Some(text) = value.as_str() {
        let timestamp = OffsetDateTime::parse(text, &Rfc3339).ok()?;
        return round_nanos_to_micros(timestamp.unix_timestamp_nanos());
    }
    let number = value.as_number()?;
    let seconds = number.as_f64()?;
    let micros = seconds * 1_000_000.0;
    if !micros.is_finite() || micros <= i64::MIN as f64 || micros >= i64::MAX as f64 {
        return None;
    }
    let rounded = if micros >= 0.0 {
        (micros + 0.5).floor()
    } else {
        (micros - 0.5).ceil()
    };
    Some(rounded as i64)
}

fn round_nanos_to_micros(nanos: i128) -> Option<i64> {
    let mut micros = nanos / 1_000;
    let remainder = nanos % 1_000;
    if remainder.unsigned_abs() >= 500 {
        micros += if nanos >= 0 { 1 } else { -1 };
    }
    i64::try_from(micros).ok()
}

fn hash(value: &str) -> String {
    Sha256::digest(value.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Codable's checkpoint uses camelCase names, while `AccountingState` is also
/// persisted by the existing token ledger with its established snake_case
/// serde contract. Keep that contract intact and adapt only this nested copy.
mod accounting_state_camel_case {
    use super::*;

    #[derive(Deserialize, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct State {
        #[serde(skip_serializing_if = "Option::is_none")]
        previous: Option<Components>,
        unreflected: Components,
        can_start_from_zero: bool,
        counter_reset: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        last_snapshot: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        paginated_own_start_ordinal: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[serde(rename = "paginatedPendingTurnID")]
        paginated_pending_turn_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        paginated_pending_turn_ordinal: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        paginated_pending_is_context: Option<bool>,
    }

    impl From<&AccountingState> for State {
        fn from(value: &AccountingState) -> Self {
            Self {
                previous: value.previous,
                unreflected: value.unreflected,
                can_start_from_zero: value.can_start_from_zero,
                counter_reset: value.counter_reset,
                last_snapshot: value.last_snapshot.clone(),
                paginated_own_start_ordinal: value.paginated_own_start_ordinal,
                paginated_pending_turn_id: value.paginated_pending_turn_id.clone(),
                paginated_pending_turn_ordinal: value.paginated_pending_turn_ordinal,
                paginated_pending_is_context: value.paginated_pending_is_context,
            }
        }
    }

    impl From<State> for AccountingState {
        fn from(value: State) -> Self {
            Self {
                previous: value.previous,
                unreflected: value.unreflected,
                can_start_from_zero: value.can_start_from_zero,
                counter_reset: value.counter_reset,
                last_snapshot: value.last_snapshot,
                paginated_own_start_ordinal: value.paginated_own_start_ordinal,
                paginated_pending_turn_id: value.paginated_pending_turn_id,
                paginated_pending_turn_ordinal: value.paginated_pending_turn_ordinal,
                paginated_pending_is_context: value.paginated_pending_is_context,
            }
        }
    }

    pub(super) fn serialize<S>(value: &AccountingState, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        State::from(value).serialize(serializer)
    }

    pub(super) fn deserialize<'de, D>(deserializer: D) -> Result<AccountingState, D::Error>
    where
        D: Deserializer<'de>,
    {
        State::deserialize(deserializer).map(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TURN_A: &str = "019ff8b9-0ace-7c02-9f89-4358b15cceda";
    const TURN_B: &str = "019ff8b9-0acf-7c02-9f89-4358b15cceda";

    fn line(value: Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    fn session_meta() -> Value {
        json!({"type":"session_meta","payload":{"id":"session-a"}})
    }

    fn turn_records(
        id: &str,
        root_ordinal: u64,
        start: i64,
        first: (i64, i64),
        last: (i64, i64),
    ) -> Vec<Value> {
        let usage = |input, cached| json!({"input_tokens":input,"cached_input_tokens":cached});
        vec![
            json!({"ordinal":root_ordinal,"timestamp":start,"type":"event_msg","payload":{"type":"task_started","turn_id":id,"started_at":start}}),
            json!({"ordinal":root_ordinal+1,"timestamp":start+1,"type":"response_item","payload":{"type":"message","role":"user"}}),
            json!({"ordinal":root_ordinal+2,"timestamp":start+2,"type":"turn_context","payload":{"turn_id":id,"model":"gpt-5.6"}}),
            json!({"ordinal":root_ordinal+3,"timestamp":start+3,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":usage(first.0,first.1),"total_token_usage":{"total_tokens":1000+root_ordinal}}}}),
            json!({"ordinal":root_ordinal+4,"timestamp":start+4,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":usage(last.0,last.1),"total_token_usage":{"total_tokens":1001+root_ordinal}}}}),
            json!({"ordinal":root_ordinal+5,"timestamp":start+6,"type":"event_msg","payload":{"type":"task_complete","turn_id":id,"completed_at":start+6}}),
        ]
    }

    fn parse(records: impl IntoIterator<Item = Value>) -> Parser {
        let mut parser = Parser::new(None);
        let known = HashSet::new();
        for record in records {
            parser.consume(&line(record), &known);
        }
        parser
    }

    #[test]
    fn first_usage_is_preserved_while_last_usage_drives_the_previous_side() {
        let mut records = vec![session_meta()];
        records.extend(turn_records(TURN_A, 1, 1_700_000_000, (100, 80), (100, 95)));
        records.extend(turn_records(
            TURN_B,
            10,
            1_700_000_220,
            (100, 90),
            (100, 99),
        ));
        let parser = parse(records);
        let pair = parser.pairs("source", "generation").remove(0);
        let point = pair.point.as_ref().unwrap();
        assert_eq!(point.previous_cached, 95);
        assert_eq!(point.cached, 90);
        assert!(pair.eligible());
        assert_eq!(serde_json::to_value(point).unwrap()["sourceKey"], "source");
        let turn_value = serde_json::to_value(&parser.turns[0]).unwrap();
        assert_eq!(turn_value["stableID"], true);
        assert!(turn_value.get("stableId").is_none());
        let pair_value = serde_json::to_value(&pair).unwrap();
        assert_eq!(pair_value["previousID"], hash(TURN_A));
        assert_eq!(pair_value["nextID"], hash(TURN_B));
        assert_eq!(pair_value["stableTurnIDs"], true);
        assert_eq!(
            pair.stable_key(),
            Some(format!(
                "{}:{}:{}",
                parser.session_key,
                hash(TURN_A),
                hash(TURN_B)
            ))
        );
    }

    #[test]
    fn invalid_first_usage_cannot_be_replaced_by_a_later_valid_usage() {
        let mut records = vec![session_meta()];
        records.extend(turn_records(TURN_A, 1, 1_700_000_000, (100, 95), (100, 95)));
        let next = turn_records(TURN_B, 10, 1_700_000_220, (0, 0), (100, 99));
        records.extend(next);
        let parser = parse(records);
        let pair = parser.pairs("source", "generation").remove(0);
        assert!(pair.reasons.contains("first_usage_invalid"));
        assert!(pair.point.is_none());
    }

    #[test]
    fn future_last_usage_keeps_its_sample_but_poison_flags_the_pair() {
        let mut records = vec![session_meta()];
        let mut previous = turn_records(TURN_A, 1, 1_700_000_000, (100, 95), (100, 99));
        previous[4]["timestamp"] = json!(1_700_000_020);
        records.extend(previous);
        records.extend(turn_records(
            TURN_B,
            10,
            1_700_000_220,
            (100, 90),
            (100, 99),
        ));
        let parser = parse(records);
        let pair = parser.pairs("source", "generation").remove(0);
        assert!(
            pair.point.is_some(),
            "The observed last sample remains intact."
        );
        assert!(!pair.eligible());
        assert!(pair.reasons.contains("usage_outside_boundary_time"));
    }

    #[test]
    fn bad_middle_turn_poisoning_preserves_adjacency_without_bridging() {
        let mut records = vec![session_meta()];
        records.extend(turn_records(TURN_A, 1, 1_700_000_000, (100, 95), (100, 95)));
        records.extend(turn_records(TURN_B, 10, 1_700_000_220, (0, 0), (100, 99)));
        let turn_c = "019ff8b9-0ad0-7c02-9f89-4358b15cceda";
        records.extend(turn_records(
            turn_c,
            20,
            1_700_000_440,
            (100, 90),
            (100, 99),
        ));
        let parser = parse(records);
        let pairs = parser.pairs("source", "generation");
        assert_eq!(pairs.len(), 2);
        assert!(pairs.iter().all(|pair| !pair.eligible()));
        assert_eq!(pairs[0].previous_id, hash(TURN_A));
        assert_eq!(pairs[0].next_id, hash(TURN_B));
        assert_eq!(pairs[1].previous_id, hash(TURN_B));
        assert!(!pairs
            .iter()
            .any(|pair| { pair.previous_id == hash(TURN_A) && pair.next_id == hash(turn_c) }));
    }

    #[test]
    fn timestamps_accept_rfc3339_microseconds_and_numeric_seconds() {
        assert_eq!(
            parse_time(&json!("2023-11-14T22:13:20.123456Z")),
            Some(1_700_000_000_123_456)
        );
        assert_eq!(
            parse_time(&json!(1_700_000_000)),
            Some(1_700_000_000_000_000)
        );
    }

    #[test]
    fn corrupt_line_abort_compaction_and_mirror_mismatch_poison_evidence() {
        let id = TURN_A;
        let mut records = vec![line(session_meta())];
        records.push(line(json!({"type":"event_msg","payload":{"type":"task_started","turn_id":id,"started_at":1_700_000_000}})));
        records.push(line(
            json!({"type":"response_item","payload":{"type":"message","role":"user"}}),
        ));
        records.push(line(
            json!({"type":"turn_context","payload":{"turn_id":id,"model":"gpt-5.6"}}),
        ));
        records.push(line(json!({"type":"token_usage_record","payload":{"turn_id":id,"usage":{"input_tokens":100,"cached_input_tokens":90}}})));
        records.push(line(json!({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80}}}})));
        records.push(b"{bad json".to_vec());
        records.push(line(
            json!({"type":"event_msg","payload":{"type":"turn_aborted"}}),
        ));
        records.push(line(
            json!({"type":"event_msg","payload":{"type":"context_compacted"}}),
        ));
        let mut parser = Parser::new(None);
        let known = HashSet::new();
        for record in records {
            parser.consume(&record, &known);
        }
        let turn = &parser.turns[0];
        assert!(turn.reasons.contains("usage_mirror_mismatch"));
        assert!(turn.reasons.contains("evidence_incomplete"));
        assert!(turn.reasons.contains("aborted"));
        assert!(turn.reasons.contains("compaction"));
    }

    #[test]
    fn paginated_inherited_prefix_is_excluded_but_two_fork_owned_turns_pair() {
        let child_id = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a";
        let child_millis = super::super::uuid_milliseconds(child_id).unwrap();
        let metadata = super::super::PaginatedSubagentMetadata {
            ordinal: 100,
            child_created_milliseconds: Some(child_millis),
            is_main_fork: false,
        };
        let mut parser = Parser::new(Some(&metadata));
        let known = HashSet::new();
        let mut records = vec![
            json!({"type":"session_meta","payload":{"id":child_id,"forked_from_id":"parent","history_mode":"paginated","subagent_history_start_ordinal":100}}),
        ];
        records.extend(turn_records(
            "019ff8b8-0001-7000-8000-000000000001",
            1,
            1_700_000_000,
            (100, 95),
            (100, 95),
        ));
        records.extend(turn_records(
            TURN_A,
            10,
            1_700_000_220,
            (100, 90),
            (100, 99),
        ));
        records.extend(turn_records(
            TURN_B,
            20,
            1_700_000_440,
            (100, 85),
            (100, 98),
        ));
        for record in records {
            parser.consume(&line(record), &known);
        }
        assert_eq!(
            parser
                .turns
                .iter()
                .filter(|turn| parser.is_own(turn))
                .count(),
            2
        );
        let pairs = parser.pairs("fork", "generation");
        assert_eq!(pairs.len(), 2);
        assert!(!pairs[0].eligible());
        assert!(pairs[0].reasons.contains("inherited"));
        assert!(pairs[1].eligible());
        assert_eq!(parser.ownership.paginated_own_start_ordinal, Some(10));
    }

    #[test]
    fn parser_checkpoint_round_trip_keeps_boundary_and_production_ownership_state() {
        let metadata = super::super::PaginatedSubagentMetadata {
            ordinal: 77,
            child_created_milliseconds: Some(1_700_000_000_000),
            is_main_fork: true,
        };
        let mut parser = Parser::new(Some(&metadata));
        parser.ownership.paginated_pending_turn_id = Some(TURN_A.into());
        parser.ownership.paginated_pending_turn_ordinal = Some(4);
        parser.ownership.paginated_pending_is_context = Some(true);
        let encoded = serde_json::to_value(&parser).unwrap();
        assert_eq!(encoded["boundary"]["childCreated"], 1_700_000_000_000_u64);
        assert_eq!(encoded["ownership"]["paginatedPendingTurnID"], TURN_A);
        assert_eq!(encoded["turns"], json!([]));
        assert_eq!(encoded["replayReference"], Value::Null);
        let decoded: Parser = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded, parser);
    }

    #[test]
    fn known_subagent_metadata_excludes_all_pairs() {
        let mut parser = Parser::new(None);
        let mut known = HashSet::new();
        known.insert("nested-agent".to_owned());
        parser.consume(
            &line(json!({"type":"session_meta","payload":{"id":"nested-agent"}})),
            &known,
        );
        parser.consume(
            &line(json!({"type":"event_msg","payload":{"type":"task_started","turn_id":TURN_A,"started_at":1_700_000_000}})),
            &known,
        );
        assert!(parser.excluded_subagent);
        assert!(parser.pairs("source", "generation").is_empty());
        assert_eq!(parser.own_turn_count(), 0);
    }
}
