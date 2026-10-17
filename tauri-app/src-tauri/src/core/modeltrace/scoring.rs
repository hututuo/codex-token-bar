//! ModelTrace's global closed-set scorer, ported from fingerprint-core.js.
//! Copyright (c) 2026 xqy2006, MIT; see LICENSES/ModelTrace-MIT.txt.
//! Keep the reference bank, temperature and candidate universe together.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::OnceLock;

const BANK_BYTES: &[u8] = include_bytes!("../../../resources/modeltrace/unified_bank.json");
pub const UPSTREAM_COMMIT: &str = "d4131b30243dfa05e70180b5eedde742103f1d73";
const DIMENSION: usize = 355;

#[derive(Deserialize)]
struct Model {
    id: String,
    display_name: String,
    family: String,
    counts: Vec<f64>,
}
#[derive(Deserialize)]
struct Projection {
    feature_mean: Vec<f64>,
    feature_scale: Vec<f64>,
    nuisance_basis: Vec<Vec<f64>>,
    centroids: Vec<Vec<f64>>,
    #[serde(default)]
    environment_centroids: Vec<Vec<Vec<f64>>>,
    #[serde(default)]
    weight: f64,
}
#[derive(Deserialize)]
struct Robust {
    hellinger: Projection,
    ordered_blocks: Projection,
}
#[derive(Deserialize)]
struct Calibration {
    beta: f64,
}
#[derive(Deserialize)]
struct Bank {
    models: Vec<Model>,
    robust: Robust,
    calibration: HashMap<String, Calibration>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub model: String,
    pub display_name: String,
    pub family: String,
    pub probability: f64,
    pub profile_similarity: f64,
    pub score: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attribution {
    pub prediction: String,
    pub candidates: Vec<Candidate>,
    pub used_outputs: usize,
    pub bank_sha256: String,
    pub upstream_commit: String,
    pub beta: f64,
}

fn bank() -> &'static Bank {
    static BANK: OnceLock<Bank> = OnceLock::new();
    BANK.get_or_init(|| {
        serde_json::from_slice(BANK_BYTES).expect("embedded ModelTrace reference bank")
    })
}

pub fn models() -> Vec<String> {
    bank()
        .models
        .iter()
        .filter(|m| m.family == "gpt")
        .map(|m| m.id.clone())
        .collect()
}

fn mean(values: &[f64]) -> f64 {
    values.iter().sum::<f64>() / values.len() as f64
}
fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}
fn normalize(mut values: Vec<f64>) -> Vec<f64> {
    let norm = dot(&values, &values).sqrt().max(1e-12);
    values.iter_mut().for_each(|v| *v /= norm);
    values
}
fn standardize(values: Vec<f64>) -> Vec<f64> {
    let center = mean(&values);
    // Population variance across the reference candidates, matching ModelTrace.
    let scale = (values.iter().map(|v| (v - center).powi(2)).sum::<f64>() / values.len() as f64)
        .sqrt()
        .max(1e-12);
    values.iter().map(|v| (v - center) / scale).collect()
}
fn project(mut values: Vec<f64>, basis: &[Vec<f64>]) -> Vec<f64> {
    for vector in basis {
        let amount = dot(&values, vector);
        values
            .iter_mut()
            .zip(vector)
            .for_each(|(v, b)| *v -= amount * b);
    }
    normalize(values)
}
fn scaled(feature: &[f64], artifact: &Projection) -> Vec<f64> {
    feature
        .iter()
        .zip(&artifact.feature_mean)
        .zip(&artifact.feature_scale)
        .map(|((v, m), s)| (v - m) / s)
        .collect()
}
fn counts(numbers: &[i64]) -> Vec<f64> {
    let mut result = vec![0.0; DIMENSION];
    for &number in numbers {
        result[number as usize - 1] += 1.0;
    }
    result
}
fn root_distribution(values: Vec<f64>) -> Vec<f64> {
    let total: f64 = values.iter().sum();
    values.iter().map(|v| (v / total).sqrt()).collect()
}
fn ordered_feature(numbers: &[i64]) -> Vec<f64> {
    let mut result = Vec::with_capacity(74);
    let mut start = 0;
    for index in 0..4 {
        let size = numbers.len() / 4 + usize::from(index < numbers.len() % 4);
        let mut bins = vec![0.5; 16];
        for &number in &numbers[start..start + size] {
            bins[((number - 1) as usize * 16 / 355).min(15)] += 1.0;
        }
        result.extend(root_distribution(bins));
        start += size;
    }
    let mut digits = vec![0.5; 10];
    for &number in numbers {
        digits[number as usize % 10] += 1.0;
    }
    result.extend(root_distribution(digits));
    result
}
fn scores(numbers: &[i64], bank: &Bank) -> Vec<f64> {
    let artifact = &bank.robust.hellinger;
    let feature = root_distribution(counts(numbers).iter().map(|v| v + 0.5).collect());
    let projected = project(scaled(&feature, artifact), &artifact.nuisance_basis);
    let marginal = standardize(
        artifact
            .centroids
            .iter()
            .map(|c| dot(&projected, c))
            .collect(),
    );
    let ordered = &bank.robust.ordered_blocks;
    let feature = scaled(&ordered_feature(numbers), ordered);
    let unit = normalize(feature.clone());
    let template = standardize(
        (0..bank.models.len())
            .map(|i| {
                ordered
                    .environment_centroids
                    .iter()
                    .map(|env| dot(&unit, &env[i]))
                    .fold(f64::NEG_INFINITY, f64::max)
            })
            .collect(),
    );
    let projected = project(feature, &ordered.nuisance_basis);
    let nuisance = standardize(
        ordered
            .centroids
            .iter()
            .map(|c| dot(&projected, c))
            .collect(),
    );
    let fused = standardize(
        template
            .iter()
            .zip(nuisance)
            .map(|(t, n)| 0.5 * t + 0.5 * n)
            .collect(),
    );
    marginal
        .iter()
        .zip(fused)
        .map(|(m, o)| (1.0 - ordered.weight) * m + ordered.weight * o)
        .collect()
}
fn similarity(left: &[f64], right: &[f64]) -> f64 {
    let left_total: f64 = left.iter().sum();
    let right_total = right.iter().sum::<f64>() + 0.5 * DIMENSION as f64;
    let divergence: f64 = left
        .iter()
        .zip(right)
        .map(|(a, b)| {
            let p = a / left_total;
            let q = (b + 0.5) / right_total;
            let mid = (p + q) / 2.0;
            ((if p > 0.0 { p * (p / mid).ln() } else { 0.0 }) + q * (q / mid).ln()) / 2.0
        })
        .sum();
    1.0 - (divergence.max(0.0) / std::f64::consts::LN_2).sqrt()
}

pub fn analyze(outputs: &[Vec<i64>]) -> Result<Attribution, String> {
    if outputs.len() != 3
        || outputs
            .iter()
            .any(|o| o.len() < 80 || o.iter().any(|n| !(1..=355).contains(n)))
    {
        return Err("归因需要 3 份有效的范围内整数回答".into());
    }
    let bank = bank();
    let scores: Vec<Vec<f64>> = outputs.iter().map(|o| scores(o, bank)).collect();
    let combined: Vec<f64> = (0..bank.models.len())
        .map(|i| scores.iter().map(|s| s[i]).sum::<f64>() / 3.0)
        .collect();
    let beta = bank.calibration["3"].beta;
    let maximum = combined
        .iter()
        .map(|s| beta * s)
        .fold(f64::NEG_INFINITY, f64::max);
    let weights: Vec<f64> = combined
        .iter()
        .map(|s| (beta * s - maximum).exp())
        .collect();
    let total: f64 = weights.iter().sum();
    let pooled = counts(&outputs.concat());
    let mut candidates: Vec<Candidate> = bank
        .models
        .iter()
        .enumerate()
        .map(|(i, model)| Candidate {
            model: model.id.clone(),
            display_name: model.display_name.clone(),
            family: model.family.clone(),
            probability: weights[i] / total,
            profile_similarity: similarity(&pooled, &model.counts),
            score: combined[i],
        })
        .collect();
    if candidates
        .iter()
        .any(|c| !c.probability.is_finite() || !c.profile_similarity.is_finite())
    {
        return Err("归因计算产生了无效数值".into());
    }
    candidates.sort_by(|a, b| b.probability.total_cmp(&a.probability));
    Ok(Attribution {
        prediction: candidates[0].model.clone(),
        candidates,
        used_outputs: outputs.len(),
        bank_sha256: format!("{:x}", Sha256::digest(BANK_BYTES)),
        upstream_commit: UPSTREAM_COMMIT.into(),
        beta,
    })
}

/// Accept one literal JSON integer array; code fences are presentation only.
/// Preserve counting/range violations in diagnostics, not in the fingerprint.
pub fn parse_output(text: &str, expected: usize) -> Result<(Vec<i64>, usize, usize), String> {
    if text.len() > 5_000 {
        return Err("回答超过长度上限".into());
    }
    let mut body = text.trim();
    if body.starts_with("```") || body.starts_with("~~~") {
        let (header, rest) = body.split_once('\n').ok_or("JSON 代码块不完整")?;
        let fence_char = header.as_bytes()[0] as char;
        let length = header.chars().take_while(|&c| c == fence_char).count();
        let fence = &header[..length];
        if !["", "json"].contains(&header[length..].trim().to_lowercase().as_str()) {
            return Err("只接受 JSON 代码块".into());
        }
        let (content, footer) = rest.rsplit_once('\n').ok_or("JSON 代码块不完整")?;
        if footer.trim() != fence {
            return Err("JSON 代码块不完整".into());
        }
        body = content.trim();
    }
    if body
        .bytes()
        .any(|c| !c.is_ascii_digit() && !c.is_ascii_whitespace() && !b"[],-".contains(&c))
    {
        return Err("只接受完整 JSON 整数数组".into());
    }
    let values: Vec<i64> = serde_json::from_str(body).map_err(|_| "回答不是完整 JSON 整数数组")?;
    let minimum = 80.max((expected as f64 * 0.55).ceil() as usize);
    if values.len() < minimum || values.len() > (expected as f64 * 1.25).ceil() as usize {
        return Err("回答中的整数数量超出可接受范围".into());
    }
    let returned = values.len();
    let in_range: Vec<i64> = values
        .into_iter()
        .filter(|n| (1..=355).contains(n))
        .collect();
    let out_of_range = returned - in_range.len();
    if in_range.len() < minimum {
        return Err("范围内整数不足，无法归因".into());
    }
    Ok((in_range, returned, out_of_range))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_upstream_javascript_fixtures() {
        let cases: serde_json::Value = serde_json::from_str(include_str!(
            "../../../resources/modeltrace/scoring-fixtures.json"
        ))
        .unwrap();
        for case in cases.as_array().unwrap() {
            let outputs: Vec<Vec<i64>> = serde_json::from_value(case["outputs"].clone()).unwrap();
            let actual = analyze(&outputs).unwrap();
            for expected in case["results"].as_array().unwrap() {
                let candidate = actual
                    .candidates
                    .iter()
                    .find(|c| c.model == expected["model"])
                    .unwrap();
                for (field, value) in [
                    ("probability", candidate.probability),
                    ("profile_similarity", candidate.profile_similarity),
                    ("score", candidate.score),
                ] {
                    assert!(
                        (value - expected[field].as_f64().unwrap()).abs() < 1e-9,
                        "{} {} {}",
                        case["name"],
                        candidate.model,
                        field
                    );
                }
            }
            assert!(
                (actual.candidates.iter().map(|c| c.probability).sum::<f64>() - 1.0).abs() < 1e-12
            );
        }
        assert_eq!(models().len(), 8);
        assert!(!models().contains(&"gpt-6.1-sol".into()));
    }
    #[test]
    fn rejects_prose_truncation_exponents_and_insufficient_samples() {
        assert!(parse_output("Here: [1, 2]", 300).is_err());
        assert!(parse_output("[1e2]", 1).is_err());
        assert!(parse_output("[1.0]", 1).is_err());
        assert!(parse_output("[1,2", 300).is_err());
        assert!(analyze(&vec![vec![1; 300]; 2]).is_err());
        let mut numbers = vec![42; 300];
        numbers.push(-1);
        let text = serde_json::to_string(&numbers).unwrap();
        let (values, returned, outliers) =
            parse_output(&format!("```json\n{text}\n```"), 300).unwrap();
        assert_eq!((values.len(), returned, outliers), (300, 301, 1));
    }
}
