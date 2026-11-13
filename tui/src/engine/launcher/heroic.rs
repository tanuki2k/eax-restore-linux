//! A game's environment variables in Heroic's `GamesConfig/<appName>.json`
//! (the key is `enviromentOptions`, Heroic's spelling). Ports of
//! `heroic_get_env` and `heroic_set_env` in `src/launcher-config.sh`, which
//! use jq: the file is written back the way jq prints it, two-space indents
//! and no trailing newline, as Heroic writes it too.

use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvValue {
    /// No file, no settings for the game, or a file jq can't read.
    NoApp,
    Absent,
    Set(String),
}

fn text(v: &Value) -> Option<String> {
    match v {
        // jq's `// "__ABSENT__"` also catches false.
        Value::Null | Value::Bool(false) => None,
        Value::String(s) => Some(s.clone()),
        other => Some(other.to_string()),
    }
}

/// The game's value for an environment variable.
pub fn get_env(path: &Path, app: &str, var: &str) -> EnvValue {
    let Some(v) = std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
    else {
        return EnvValue::NoApp;
    };
    let Some(game) = v
        .as_object()
        .and_then(|o| o.get(app))
        .filter(|g| g.is_object())
    else {
        return EnvValue::NoApp;
    };
    let options: Vec<&Value> = match game.get("enviromentOptions") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => Vec::new(),
        Some(Value::Array(a)) => a.iter().collect(),
        Some(Value::Object(o)) => o.values().collect(),
        // jq can't iterate anything else, and the script falls back.
        Some(_) => return EnvValue::NoApp,
    };
    let mut first = None;
    for o in options {
        // `.key` on anything but an object or null stops jq.
        let key = match o {
            Value::Object(m) => m.get("key"),
            Value::Null => None,
            _ => return EnvValue::NoApp,
        };
        if first.is_none() && key == Some(&Value::String(var.to_string())) {
            first = Some(o.get("value").cloned().unwrap_or(Value::Null));
        }
    }
    match first.as_ref().and_then(text) {
        Some(s) => EnvValue::Set(s),
        None => EnvValue::Absent,
    }
}

/// Sets the variable (adding it at the end of the list when it isn't there)
/// or with `None` removes every entry for it. The game's settings are
/// created when the file has none.
pub fn set_env(data: &str, app: &str, var: &str, value: Option<&str>) -> Result<String> {
    let mut v: Value = serde_json::from_str(data)?;
    let Some(root) = v.as_object_mut() else {
        bail!("the file isn't a JSON object");
    };
    let game = root.entry(app.to_string()).or_insert_with(|| json!({}));
    if game.is_null() {
        *game = json!({});
    }
    let Some(game) = game.as_object_mut() else {
        bail!("the game's settings aren't a JSON object");
    };
    // Taken in place, so the key keeps its position in the object.
    let slot = game.entry("enviromentOptions").or_insert(Value::Null);
    let list = match std::mem::take(slot) {
        Value::Null | Value::Bool(false) => Vec::new(),
        Value::Array(a) => a,
        _ => bail!("enviromentOptions isn't a list"),
    };
    let is_var = |o: &Value| o.get("key") == Some(&Value::String(var.to_string()));
    let list: Vec<Value> = match value {
        None => list.into_iter().filter(|o| !is_var(o)).collect(),
        Some(val) if list.iter().any(is_var) => list
            .into_iter()
            .map(|mut o| {
                if is_var(&o) {
                    o["value"] = Value::String(val.to_string());
                }
                o
            })
            .collect(),
        Some(val) => {
            let mut list = list;
            list.push(json!({ "key": var, "value": val }));
            list
        }
    };
    *slot = Value::Array(list);
    Ok(pretty(&v))
}

/// jq's layout: two-space indents, `"key": value`, and empty lists and
/// objects as `[]` and `{}`.
fn pretty(v: &Value) -> String {
    let mut buf = Vec::new();
    let fmt = serde_json::ser::PrettyFormatter::with_indent(b"  ");
    let mut ser = serde_json::Serializer::with_formatter(&mut buf, fmt);
    serde::Serialize::serialize(v, &mut ser).expect("a JSON value serialises");
    String::from_utf8(buf).expect("serde_json writes UTF-8")
}

/// [`set_env`] on the file, through a temp file beside it.
pub fn set_env_file(path: &Path, app: &str, var: &str, value: Option<&str>) -> Result<()> {
    let data = std::fs::read_to_string(path)?;
    let out = set_env(&data, app, var, value)?;
    crate::engine::files::write_through_temp(path, out.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_get_remove() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("g.json");
        std::fs::write(
            &f,
            r#"{"g":{"enviromentOptions":[{"key":"A","value":"1"}]},"version":"v0"}"#,
        )
        .unwrap();
        assert_eq!(get_env(&f, "g", "A"), EnvValue::Set("1".into()));
        assert_eq!(get_env(&f, "g", "B"), EnvValue::Absent);
        assert_eq!(get_env(&f, "other", "A"), EnvValue::NoApp);
        set_env_file(&f, "g", "B", Some("x y")).unwrap();
        assert_eq!(get_env(&f, "g", "B"), EnvValue::Set("x y".into()));
        set_env_file(&f, "g", "A", None).unwrap();
        assert_eq!(get_env(&f, "g", "A"), EnvValue::Absent);
        let text = std::fs::read_to_string(&f).unwrap();
        assert!(text.starts_with("{\n  \"g\": {\n    \"enviromentOptions\": [\n"));
        assert!(!text.ends_with('\n'));
    }
}
