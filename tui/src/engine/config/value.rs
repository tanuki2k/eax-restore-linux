//! A setting's value as it travels between the database, a config file and
//! the manifest: plain text, or one of the markers the Bash script uses.

use super::Format;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// `__ABSENT__`: the key isn't in the file (read side only).
    Absent,
    /// `__TRUE__`: a `key_value` flag that is switched on.
    True,
    /// `__FALSE__`: a `key_value` flag that is only there commented out.
    False,
    /// `__DELETE__`: remove the key (write side only).
    Delete,
    /// `__RAW__`: a registry value of a type that is never changed.
    Raw,
    /// Anything else, as the bytes the file holds (not always UTF-8).
    Text(Vec<u8>),
}

impl Value {
    /// The value for a marker or any other text.
    pub fn from_bytes(text: &[u8]) -> Self {
        match text {
            b"__ABSENT__" => Value::Absent,
            b"__TRUE__" => Value::True,
            b"__FALSE__" => Value::False,
            b"__DELETE__" => Value::Delete,
            b"__RAW__" => Value::Raw,
            _ => Value::Text(text.to_vec()),
        }
    }

    pub fn text(text: &str) -> Self {
        Value::from_bytes(text.as_bytes())
    }

    /// The marker or the text, as the script and the manifest spell it.
    pub fn as_bytes(&self) -> &[u8] {
        match self {
            Value::Absent => b"__ABSENT__",
            Value::True => b"__TRUE__",
            Value::False => b"__FALSE__",
            Value::Delete => b"__DELETE__",
            Value::Raw => b"__RAW__",
            Value::Text(t) => t,
        }
    }

    /// `config_display_value`: how a value reads on screen.
    pub fn display(&self) -> String {
        match self {
            Value::Absent => "(not set)".into(),
            Value::True => "on".into(),
            Value::False => "off".into(),
            Value::Delete => "(removed)".into(),
            Value::Raw => "(binary)".into(),
            Value::Text(t) if t.is_empty() => "(empty)".into(),
            Value::Text(t) => String::from_utf8_lossy(t).into_owned(),
        }
    }
}

/// Up to ten digits, the numbers the script compares as numbers.
fn as_number(text: &[u8]) -> Option<u64> {
    if text.is_empty() || text.len() > 10 || !text.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(text).ok()?.parse().ok()
}

fn lowercase(text: &[u8]) -> Vec<u8> {
    match std::str::from_utf8(text) {
        Ok(s) => s.to_lowercase().into_bytes(),
        Err(_) => text.to_ascii_lowercase(),
    }
}

/// `config_values_equal`: ini values compare without case (Unreal reads
/// "True" and "true" the same) and so do registry strings; registry and
/// binary numbers compare as numbers ("03" is 3); the rest must match
/// exactly. Removing a key and the key not being there are the same state.
pub fn values_equal(format: Format, a: &Value, b: &Value) -> bool {
    if matches!(
        (a, b),
        (Value::Absent, Value::Delete) | (Value::Delete, Value::Absent)
    ) {
        return true;
    }
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if matches!(
        format,
        Format::Registry | Format::BinaryOffset | Format::BinaryText
    ) {
        if let (Some(x), Some(y)) = (as_number(a), as_number(b)) {
            return x == y;
        }
    }
    if matches!(format, Format::Ini | Format::IniBraces | Format::Registry) {
        return lowercase(a) == lowercase(b);
    }
    a == b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers_round_trip() {
        for m in [
            "__ABSENT__",
            "__TRUE__",
            "__FALSE__",
            "__DELETE__",
            "__RAW__",
            "x",
            "",
        ] {
            assert_eq!(Value::text(m).as_bytes(), m.as_bytes());
        }
    }

    #[test]
    fn equality_follows_the_format() {
        let t = Value::text;
        assert!(values_equal(Format::Ini, &t("True"), &t("true")));
        assert!(!values_equal(Format::SetCommands, &t("True"), &t("true")));
        assert!(values_equal(Format::Registry, &t("03"), &t("3")));
        assert!(!values_equal(Format::Ini, &t("03"), &t("3")));
        assert!(values_equal(
            Format::KeyValue,
            &Value::Absent,
            &Value::Delete
        ));
        assert!(!values_equal(Format::KeyValue, &Value::Absent, &t("")));
    }

    #[test]
    fn display_names_the_markers() {
        assert_eq!(Value::Absent.display(), "(not set)");
        assert_eq!(Value::text("").display(), "(empty)");
        assert_eq!(Value::True.display(), "on");
        assert_eq!(Value::text("quad").display(), "quad");
    }
}
