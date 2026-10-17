pub(crate) mod probe;
pub(crate) mod scoring;
pub(crate) mod store;

use serde::{Deserialize, Serialize};

pub const DEFAULT_ROUNDS: usize = 1;
pub const MAX_ROUNDS: usize = 5;
pub const MAX_ATTEMPTS: usize = 6;
pub const INTERVAL_SECONDS: i64 = 3600;
pub const MISSED_GRACE_SECONDS: i64 = 300;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub id: String,
    pub model: String,
    pub started_at: i64,
    pub status: String,
    #[serde(default = "legacy_rounds")]
    pub total_rounds: usize,
    pub completed_rounds: usize,
    pub current_attempt: usize,
    pub valid_samples: usize,
    pub next_run_at: Option<i64>,
    pub error: Option<String>,
}
// Plans saved before round selection was added always scheduled three rounds.
fn legacy_rounds() -> usize {
    3
}
pub fn validate_rounds(rounds: usize) -> Result<(), String> {
    if !(1..=MAX_ROUNDS).contains(&rounds) {
        return Err("检测轮数必须为 1 至 5 轮".into());
    }
    Ok(())
}
impl Plan {
    pub fn active(&self) -> bool {
        matches!(self.status.as_str(), "waiting" | "running" | "cancelling")
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub id: String,
    pub plan_id: String,
    pub model: String,
    pub started_at: i64,
    pub completed_at: i64,
    pub status: String,
    pub attempts: usize,
    pub valid_samples: usize,
    pub message: Option<String>,
    pub attribution: Option<scoring::Attribution>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub models: Vec<String>,
    pub scope_key: String,
    pub plan: Option<Plan>,
    pub latest: Option<Run>,
    pub bank_version: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub scope_key: String,
    pub runs: Vec<Run>,
    pub has_more: bool,
}

pub fn judgement(model: &str, attribution: &scoring::Attribution) -> &'static str {
    if !scoring::models().iter().any(|m| m == model) {
        return "reference_missing";
    }
    if attribution.candidates.len() > 1
        && (attribution.candidates[0].probability - attribution.candidates[1].probability).abs()
            < 1e-12
    {
        return "inconclusive";
    }
    if attribution.prediction == model {
        "candidate_matches"
    } else {
        "candidate_differs"
    }
}

pub fn slot_action(start: i64, slot: usize, now: i64) -> &'static str {
    let due = start + slot as i64 * INTERVAL_SECONDS;
    if now < due {
        "wait"
    } else if now - due > MISSED_GRACE_SECONDS {
        "missed"
    } else {
        "run"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn plans_keep_original_schedule_and_skip_missed_slots() {
        assert_eq!(slot_action(1000, 0, 1000), "run");
        assert_eq!(slot_action(1000, 1, 4599), "wait");
        assert_eq!(slot_action(1000, 1, 4600), "run");
        assert_eq!(slot_action(1000, 1, 4900), "run");
        assert_eq!(slot_action(1000, 1, 4901), "missed");
        assert_eq!(slot_action(1000, 2, 8200), "run");
    }
}
