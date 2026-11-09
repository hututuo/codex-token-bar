//! Display identity plus explicitly confirmed billing aliases. Only
//! `billing_identifier` is used by pricing; raw ledger IDs stay authoritative.
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelPresentationIdentity { pub key:String, pub label:String, pub kind:String }
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Policy {
    unsafe_scalar_ranges:Vec<[u32;2]>,
    wrappers:Vec<String>,missing:Vec<String>,ambiguous:Vec<String>,
    modifiers:BTreeMap<String,Vec<String>>,routing_labels:BTreeMap<String,String>,source_labels:BTreeMap<String,String>,
    billing_aliases:BTreeMap<String,String>,
    #[serde(default)] display_aliases:BTreeMap<String,String>,
}
#[derive(Deserialize)]
struct Names { names:BTreeMap<String,String> }
#[derive(Deserialize)]
struct Model { id:String,name:String,#[serde(default)] aliases:Vec<String> }
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Rules { bedrock_regions:Vec<String>,bedrock_vendors:Vec<String> }
#[derive(Deserialize)]
struct Prices { models:Vec<Model>,normalize:Rules }
struct Catalog { policy:Policy,names:Names,prices:Prices,aliases:BTreeMap<String,String> }
fn normalized(raw:&str)->String { raw.trim().to_lowercase().replace('_',"-") }
fn modifiers(raw:&str,policy:&Policy)->String {
    let mut key=raw.to_string();
    for (prefix,suffixes) in &policy.modifiers {
        if !key.starts_with(prefix) { continue; }
        while let Some(suffix)=suffixes.iter().find(|s|key.ends_with(s.as_str())) { key.truncate(key.len()-suffix.len()); }
        break;
    }
    key
}
fn shape(raw:&str,policy:&Policy)->String {
    let mut key=modifiers(&normalized(raw).replace(' ',"-").replace(['(',')'],""),policy);
    if key.starts_with("claude-") {
        key=key.replace('.',"-");
        if let Some((base,last))=key.rsplit_once('-') {
            if last.len()==8 && last.bytes().all(|b|b.is_ascii_digit()) {key=base.to_string();}
        }
    }
    key
}
fn catalog()->&'static Catalog {
    static VALUE:OnceLock<Catalog>=OnceLock::new();
    VALUE.get_or_init(||{
        let policy:Policy=serde_json::from_str(include_str!("../../../../Sources/CodexTokenBar/Resources/model-presentation-policy.json")).expect("bundled presentation policy");
        let names:Names=serde_json::from_str(include_str!("../../../../Sources/CodexTokenBar/Resources/model-display-names.json")).expect("bundled labels");
        let prices:Prices=serde_json::from_str(include_str!("../../../../Vendor/AgentSpeed/spec/assets/prices.json")).expect("bundled model catalog");
        let mut aliases=BTreeMap::new();let mut ambiguous=BTreeSet::new();
        for m in &prices.models { for raw in std::iter::once(&m.id).chain(std::iter::once(&m.name)).chain(&m.aliases) {
            if shape(raw,&policy)!=shape(&m.id,&policy) {continue;}
            let key=normalized(raw);
            if policy.ambiguous.contains(&key)||ambiguous.contains(&key) {continue;}
            if aliases.get(&key).is_some_and(|id|id!=&m.id) {aliases.remove(&key);ambiguous.insert(key);}
            else {aliases.insert(key,m.id.clone());}
        }}
        Catalog {policy,names,prices,aliases}
    })
}
fn identity(key:&str,label:&str,kind:&str)->ModelPresentationIdentity {
    ModelPresentationIdentity {key:key.into(),label:label.into(),kind:kind.into()}
}
fn known(value:&str,suffix:&str,c:&Catalog)->Option<ModelPresentationIdentity> {
    let id=c.aliases.get(value)?;let label=c.names.names.get(id)?;
    Some(identity(&(id.clone()+suffix),&(label.clone()+if suffix.contains("-fast"){" Fast"}else{""}+if suffix.contains(":free"){" Free"}else{""}),"known"))
}
pub fn resolve(raw:&str)->ModelPresentationIdentity {
    let c=catalog();let p=&c.policy;let original=raw.trim();let mut key=normalized(original);
    key=billing_identifier(&key).to_string();
    key=p.display_aliases.get(&key).cloned().unwrap_or(key);
    if p.missing.contains(&key) {return identity("unknown","未报告模型","unreported");}
    if p.ambiguous.contains(&key) {return identity("gpt-5.6-generic","5.6（未分型）","ambiguous");}
    if let Some(label)=p.routing_labels.get(&key) {return identity(&key,label,"routing");}
    if let Some(label)=p.source_labels.get(&key) {return identity(&key,label,"source");}
    if let Some(hit)=known(&key,"",c) {return hit;}
    if let Some(prefix)=p.wrappers.iter().find(|prefix|key.starts_with(prefix.as_str())) {key=key[prefix.len()..].into();}
    key=billing_identifier(&key).to_string();
    for region in &c.prices.normalize.bedrock_regions {
        if let Some(rest)=key.strip_prefix(&(region.clone()+".")) {
            if c.prices.normalize.bedrock_vendors.iter().any(|v|rest.starts_with(&(v.clone()+"."))) {key=rest.into();}break;
        }
    }
    for vendor in &c.prices.normalize.bedrock_vendors {
        if let Some(rest)=key.strip_prefix(&(vendor.clone()+".")) {
            key=rest.into();
            if let Some((base,version))=key.rsplit_once("-v") {
                let parts:Vec<_>=version.split(':').collect();
                if parts.len()<=2&&parts.iter().all(|p|!p.is_empty()&&p.bytes().all(|b|b.is_ascii_digit())) {key=base.into();}
            }break;
        }
    }
    let mut suffix=String::new();
    for free in [":free","-free"] {if key.ends_with(free) {key.truncate(key.len()-free.len());suffix=":free".into();break;}}
    if key.ends_with("-fast") {key.truncate(key.len()-5);suffix="-fast".to_string()+&suffix;}
    if let Some(hit)=known(&key,&suffix,c) {return hit;}
    key=modifiers(&key,p);if let Some(hit)=known(&key,&suffix,c) {return hit;}
    if key.starts_with("claude-") {key=key.replace('.',"-");}
    if let Some(hit)=known(&key,&suffix,c) {return hit;}
    // Match the shared invalid-label contract, including directional controls.
    let invalid=original.chars().count()>160 || original.chars().any(|ch| {
        let value=ch as u32;
        p.unsafe_scalar_ranges.iter().any(|[lo,hi]|*lo<=value&&value<=*hi) || matches!(ch,'{'|'}')
    });
    identity(original,if invalid {"异常模型标识"} else {original},if invalid {"invalid"} else {"unknown"})
}

/// Only explicitly confirmed route slots affect billing. Raw IDs stay intact.
pub(crate) fn billing_identifier(identifier:&str)->&str {
    catalog().policy.billing_aliases.get(identifier).map(String::as_str).unwrap_or(identifier)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn presentation_identity_matches_shared_cross_platform_cases() {
        let rows:serde_json::Value=serde_json::from_str(include_str!("../../../../Sources/CodexTokenBar/Resources/model-presentation-cases.json")).unwrap();
        for row in rows.as_array().unwrap() {
            let raw=row["raw"].as_str().unwrap();
            assert_eq!(serde_json::to_value(resolve(raw)).unwrap(),row["expected"],"{raw}");
        }
    }
}
