use serde_json::{Value,Map};
pub(super) fn project(value:&Value,depth:usize)->Value {
    let mut out=Map::new();if depth>=5{return Value::Object(out)}
    let Some(object)=value.as_object() else{return Value::Object(out)};
    for (key,value) in object {
        if ["events","metrics","objects","reports","numericRecords","updaterReceipts"].contains(&key.as_str()){
            if value.is_object(){out.insert(key.clone(),project(value,depth+1));}
            if let Some(rows)=value.as_array(){out.insert(key.clone(),Value::Array(rows.iter().take(6000).map(|v|project(v,depth+1)).collect()));}
        }else if value.is_number() && (super::allowed_metric(key)||["schema","at","source","rejected","omitted","osMajor","osMinor","osPatch","processorCount","processCount","freeBytes","object","modifiedAt","startedAt","bugType","retryCount"].contains(&key.as_str())){
            out.insert(key.clone(),value.clone());
        }else if value.is_boolean()&&["present","regular","symlink","ownerMatches","expectedBundleIdentity","applicationPresent","databaseQueriesPerformed","rawLogsIncluded","rawTextExcluded","stacksAndMemoryExcluded"].contains(&key.as_str()){
            out.insert(key.clone(),value.clone());
        }else if let Some(text)=value.as_str(){
            let safe=match key.as_str(){
                "version"|"build"|"targetVersion"|"targetBuild"|"sourceVersion"=>Some(super::version(text)),
                "session"|"attempt"=>uuid::Uuid::parse_str(text).ok().map(|u|u.to_string()),
                "area"=>serde_json::from_value::<super::Area>(value.clone()).ok().map(|_|text.to_string()),
                "phase"=>if text=="failure"||serde_json::from_value::<super::Phase>(value.clone()).is_ok(){Some(text.to_string())}else{None},
                "status"|"signatureCheck"=>Some(if ["ok","unavailable","timeout","failed","pending","launchFailed","confirmed"].contains(&text){text}else{"unavailable"}.into()),
                "platform"=>["macos","windows","linux"].contains(&text).then(||text.into()),
                "architecture"=>["arm64","aarch64","x86_64","x86"].contains(&text).then(||text.into()),
                "stateSource"=>(text=="persisted_diagnostic_events").then(||text.into()),
                _=>None,
            };
            if let Some(text)=safe{out.insert(key.clone(),Value::String(text));}
        }
    }
    Value::Object(out)
}
