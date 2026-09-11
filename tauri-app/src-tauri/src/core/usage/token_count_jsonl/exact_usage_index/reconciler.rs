//! Per-source ledger reconciliation, shared semantics with UsageLedgerReconciler.swift.
//! No IO and no deletion: source offsets/timestamps are never request identity.
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Components {
    pub input: i64,
    pub cached: i64,
    pub output: i64,
    pub reasoning: i64,
}

impl Components {
    fn valid(&self) -> bool {
        self.input >= 0 && self.output >= 0 && self.cached >= 0 && self.cached <= self.input
            && self.reasoning >= 0 && self.reasoning <= self.output
            && self.input.checked_add(self.output).is_some()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Observation {
    pub id: String,
    pub source: String,
    pub timestamp_millis: i64,
    pub components: Components,
    /// Proven request identity or complete snapshot scoped to source/counter epoch.
    pub identity: Option<String>,
    pub timestamp_trusted: bool,
    /// Caller has append proof or independent proof of new consumption.
    pub confirmed_new: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Match {
    pub historical_id: String,
    pub observation_id: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Reconciliation {
    pub retained: Vec<Observation>,
    pub inserted: Vec<Observation>,
    pub matches: Vec<Match>,
    pub unresolved: Vec<Observation>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Failure {
    MixedSources, InvalidComponents, DuplicateId, InvalidIdentity, ConflictingHistoricalIdentity,
}

pub(super) fn reconcile(history: &[Observation], incoming: &[Observation]) -> Result<Reconciliation, Failure> {
    let mut sources = HashSet::new();
    let mut ids = HashSet::new();
    for record in history.iter().chain(incoming) {
        sources.insert(&record.source);
        if sources.len() > 1 { return Err(Failure::MixedSources); }
        if !record.components.valid() { return Err(Failure::InvalidComponents); }
        if !ids.insert(&record.id) { return Err(Failure::DuplicateId); }
        if record.id.is_empty() || record.source.is_empty() || record.identity.as_deref() == Some("") {
            return Err(Failure::InvalidIdentity);
        }
    }
    let mut identities = HashMap::new();
    for record in history {
        if let Some(identity) = &record.identity {
            if identities.insert(identity, record).is_some() { return Err(Failure::ConflictingHistoricalIdentity); }
        }
    }
    let mut result = Reconciliation { retained: history.to_vec(), inserted: vec![], matches: vec![], unresolved: vec![] };
    for record in incoming {
        if let Some(old) = record.identity.as_ref().and_then(|id| identities.get(id)) {
            if old.components == record.components {
                result.matches.push(Match { historical_id: old.id.clone(), observation_id: record.id.clone() });
            } else {
                result.unresolved.push(record.clone());
            }
        } else if record.confirmed_new {
            result.inserted.push(record.clone());
            if let Some(identity) = &record.identity { identities.insert(identity, record); }
        } else {
            result.unresolved.push(record.clone());
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(id: &str, tokens: i64, identity: Option<&str>, fresh: bool) -> Observation {
        Observation { id: id.into(), source: "child".into(), timestamp_millis: 1000,
            components: Components { input: tokens, cached: 0, output: 0, reasoning: 0 },
            identity: identity.map(String::from), timestamp_trusted: true, confirmed_new: fresh }
    }
    fn total(result: &Reconciliation) -> i64 {
        result.retained.iter().chain(&result.inserted).map(|e| e.components.input + e.components.output).sum()
    }
    #[test]
    fn rewrite_reopen_and_append_preserve_missing_history_without_counting_overlap() {
        let old = [event("A",80,Some("a"),false),event("B",20,Some("b"),false)];
        let mut observed = event("observed-b",20,Some("b"),false);
        observed.timestamp_millis=1; observed.timestamp_trusted=false;
        let result = reconcile(&old,&[observed,event("C",5,Some("c"),true)]).unwrap();
        assert_eq!(total(&result),105);
        assert_eq!(result.retained,old);
        assert_eq!(result.matches[0].historical_id,"B");
        assert!(result.unresolved.is_empty());
        let history: Vec<_> = result.retained.into_iter().chain(result.inserted).collect();
        let reopened = reconcile(&history,&[event("C-again",5,Some("c"),false)]).unwrap();
        assert_eq!(total(&reopened),105);
        let appended = reconcile(&reopened.retained,&[event("D",7,Some("d"),true)]).unwrap();
        assert_eq!(total(&appended),112);
    }
    #[test]
    fn equal_values_with_distinct_request_ids_are_distinct() {
        let result = reconcile(&[event("A",20,Some("a"),false)],&[event("B",20,Some("b"),true)]).unwrap();
        assert_eq!(total(&result),40); assert!(result.matches.is_empty());
    }
    #[test]
    fn rewritten_untrusted_timestamp_cannot_invent_match_or_new_consumption() {
        let mut incoming=event("maybe-a",80,None,false);
        incoming.timestamp_millis=1; incoming.timestamp_trusted=false;
        let result=reconcile(&[event("A",80,None,false)],&[incoming,event("unknown",5,None,false)]).unwrap();
        assert_eq!(total(&result),80); assert_eq!(result.unresolved.len(),2);
    }
    #[test]
    fn repeated_proven_identity_in_batch_is_one_insertion() {
        let result=reconcile(&[],&[event("A",20,Some("request"),true),event("alias",20,Some("request"),true)]).unwrap();
        assert_eq!(total(&result),20); assert_eq!(result.matches.len(),1);
    }
    #[test]
    fn conflicting_components_require_explicit_correction() {
        let result=reconcile(&[event("A",80,Some("a"),false)],&[event("changed-a",70,Some("a"),true)]).unwrap();
        assert_eq!(total(&result),80); assert_eq!(result.unresolved.len(),1);
    }
    #[test]
    fn sources_cannot_merge_across_tasks_or_accounts() {
        let mut other=event("B",5,None,true); other.source="other-child".into();
        assert_eq!(reconcile(&[event("A",80,None,false)],&[other]),Err(Failure::MixedSources));
    }
    #[test]
    fn equal_trusted_time_and_components_alone_cannot_merge_requests() {
        let result=reconcile(&[event("A",20,None,false)],&[event("B",20,None,true),event("unknown",20,None,false)]).unwrap();
        assert_eq!(total(&result),40); assert!(result.matches.is_empty()); assert_eq!(result.unresolved.len(),1);
    }
    #[test]
    fn reused_ids_and_empty_identity_are_rejected() {
        assert_eq!(reconcile(&[event("A",80,None,false)],&[event("A",5,None,true)]),Err(Failure::DuplicateId));
        assert_eq!(reconcile(&[],&[event("B",5,Some(""),true)]),Err(Failure::InvalidIdentity));
    }
}
