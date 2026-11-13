//! The player's speaker setup: what the speaker questions record, the
//! alsoft.ini values it turns into, and reading those back from a generated
//! alsoft.ini. Ports of `speaker_alsoft_values`, `speaker_label`,
//! `speaker_config_from_alsoft` and `speakers_match` in `src/game-config.sh`.

use super::config::{self, Format, Value};
use anyhow::Result;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Output {
    /// Headphones, or two speakers.
    Stereo,
    /// Four to eight speakers.
    Surround,
    /// Stereo that a receiver or soundbar decodes into surround.
    Matrix,
}

/// What a stereo output is listened on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Listening {
    /// OpenAL Soft works it out.
    Auto,
    Speakers,
    Headphones,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Quad,
    Surround51,
    Surround61,
    Surround71,
}

impl Layout {
    pub const ALL: [Layout; 4] = [
        Layout::Quad,
        Layout::Surround51,
        Layout::Surround61,
        Layout::Surround71,
    ];

    /// alsoft.ini's name for it, which the database's `only_if.speakers` uses too.
    pub fn name(self) -> &'static str {
        match self {
            Layout::Quad => "quad",
            Layout::Surround51 => "surround51",
            Layout::Surround61 => "surround61",
            Layout::Surround71 => "surround71",
        }
    }

    fn from_name(name: &[u8]) -> Option<Self> {
        Layout::ALL
            .into_iter()
            .find(|l| l.name().as_bytes() == name)
    }
}

impl Listening {
    pub fn name(self) -> &'static str {
        match self {
            Listening::Auto => "auto",
            Listening::Speakers => "speakers",
            Listening::Headphones => "headphones",
        }
    }
}

/// One speaker setup. `listening` and `hrtf` only mean something for
/// stereo, `layout` only for surround.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Speakers {
    pub output: Output,
    pub listening: Listening,
    /// Binaural 3D sound for headphones. Never on for stereo speakers.
    pub hrtf: bool,
    pub layout: Layout,
}

impl Default for Speakers {
    /// What every question starts on when nothing is known yet.
    fn default() -> Self {
        Speakers {
            output: Output::Stereo,
            listening: Listening::Auto,
            hrtf: true,
            layout: Layout::Surround51,
        }
    }
}

/// The alsoft.ini values for a speaker setup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlsoftValues {
    pub channels: &'static str,
    pub stereo_mode: &'static str,
    pub stereo_encoding: &'static str,
    /// `[general] hrtf-mode`, which is always `full`; written commented out
    /// when HRTF is off.
    pub hrtf_on: bool,
    /// `[decoder] hq-mode = true`, for surround.
    pub hq_decoder: bool,
}

impl Speakers {
    pub fn stereo(listening: Listening, hrtf: bool) -> Self {
        Speakers {
            output: Output::Stereo,
            listening,
            // HRTF is for headphones; over real speakers it only blurs where
            // sounds come from.
            hrtf: hrtf && listening != Listening::Speakers,
            ..Speakers::default()
        }
    }

    pub fn surround(layout: Layout) -> Self {
        Speakers {
            output: Output::Surround,
            hrtf: false,
            layout,
            ..Speakers::default()
        }
    }

    pub fn matrix() -> Self {
        Speakers {
            output: Output::Matrix,
            hrtf: false,
            ..Speakers::default()
        }
    }

    pub fn alsoft_values(&self) -> AlsoftValues {
        match self.output {
            // Surround and matrix bypass HRTF and the stereo-only encodings;
            // the matrix decoder (tsme) needs an unprocessed stereo signal.
            Output::Surround => AlsoftValues {
                channels: self.layout.name(),
                stereo_mode: "auto",
                stereo_encoding: "basic",
                hrtf_on: false,
                hq_decoder: true,
            },
            Output::Matrix => AlsoftValues {
                channels: "stereo",
                stereo_mode: "auto",
                stereo_encoding: "tsme",
                hrtf_on: false,
                hq_decoder: false,
            },
            Output::Stereo => AlsoftValues {
                channels: "stereo",
                stereo_mode: self.listening.name(),
                stereo_encoding: if self.hrtf { "hrtf" } else { "basic" },
                hrtf_on: self.hrtf,
                hq_decoder: false,
            },
        }
    }

    /// The setup in a few words ("Headphones, HRTF on", "Surround 5.1").
    pub fn label(&self) -> String {
        match self.output {
            Output::Stereo => {
                let base = match self.listening {
                    Listening::Speakers => "Stereo speakers",
                    Listening::Headphones => "Headphones",
                    Listening::Auto => "Stereo (OpenAL Soft decides)",
                };
                if self.hrtf {
                    format!("{base}, HRTF on")
                } else {
                    base.to_string()
                }
            }
            Output::Surround => match self.layout {
                Layout::Quad => "Quad (4.0)",
                Layout::Surround51 => "Surround 5.1",
                Layout::Surround61 => "Surround 6.1",
                Layout::Surround71 => "Surround 7.1",
            }
            .to_string(),
            Output::Matrix => "Matrix encoding".to_string(),
        }
    }

    /// Reads a generated alsoft.ini's channels, stereo-mode and
    /// stereo-encoding back into a setup. `None` when it has no channels line.
    pub fn from_alsoft(path: &Path) -> Option<Self> {
        let get = |key| config::get_file(path, Format::Ini, "general", key);
        let channels = get("channels");
        if channels == Value::Absent {
            return None;
        }
        let listening = match get("stereo-mode").as_bytes() {
            b"speakers" => Listening::Speakers,
            b"headphones" => Listening::Headphones,
            _ => Listening::Auto,
        };
        let encoding = get("stereo-encoding");
        let speakers = match Layout::from_name(channels.as_bytes()) {
            Some(layout) => Speakers::surround(layout),
            None if encoding.as_bytes() == b"tsme" => Speakers::matrix(),
            None => Speakers {
                output: Output::Stereo,
                listening,
                hrtf: encoding.as_bytes() == b"hrtf",
                ..Speakers::default()
            },
        };
        // The script keeps the stereo-mode it read whatever the output.
        Some(Speakers {
            listening,
            ..speakers
        })
    }

    /// Writes this setup into an existing alsoft.ini, as Tools → Speaker
    /// configuration does. hrtf-mode is only written when HRTF is on: a file
    /// generated with it off has it commented out, and this leaves it so.
    pub fn write_alsoft(&self, path: &Path) -> Result<()> {
        let v = self.alsoft_values();
        let set =
            |sec, key, val: &str| config::set_file(path, Format::Ini, sec, key, &Value::text(val));
        let mut result = set("general", "channels", v.channels);
        for (key, val) in [
            ("stereo-mode", v.stereo_mode),
            ("stereo-encoding", v.stereo_encoding),
        ] {
            let r = set("general", key, val);
            result = result.and(r);
        }
        if v.hrtf_on {
            result = result.and(set("general", "hrtf-mode", "full"));
        }
        if v.hq_decoder {
            result = result.and(set("decoder", "hq-mode", "true"));
        }
        result
    }

    /// True when a setting's `only_if.speakers` list takes this setup:
    /// stereo / matrix / surround (any layout) match the output, headphones
    /// matches Stereo → Headphones (not Auto), and an exact layout
    /// (quad, surround51, ...) matches it. When the game has its own
    /// headphones setting (`has_headphones`), stereo stops matching
    /// headphones, since both usually set the same key.
    pub fn matches(&self, wanted: &[String], has_headphones: bool) -> bool {
        let headphones = self.listening == Listening::Headphones;
        wanted.iter().any(|v| {
            let v = v.as_str();
            if v == "stereo" && has_headphones && headphones {
                return false;
            }
            let output = match self.output {
                Output::Stereo => "stereo",
                Output::Surround => "surround",
                Output::Matrix => "matrix",
            };
            v == output
                || (v == "headphones" && self.output == Output::Stereo && headphones)
                || (self.output == Output::Surround && v == self.layout.name())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_speakers_never_get_hrtf() {
        let s = Speakers::stereo(Listening::Speakers, true);
        assert!(!s.hrtf);
        assert_eq!(s.label(), "Stereo speakers");
        let h = Speakers::stereo(Listening::Headphones, true);
        assert_eq!(h.label(), "Headphones, HRTF on");
        assert_eq!(h.alsoft_values().stereo_encoding, "hrtf");
    }

    #[test]
    fn matching() {
        let w = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        let phones = Speakers::stereo(Listening::Headphones, false);
        assert!(phones.matches(&w(&["stereo"]), false));
        assert!(!phones.matches(&w(&["stereo"]), true));
        assert!(phones.matches(&w(&["headphones"]), true));
        assert!(!Speakers::stereo(Listening::Auto, false).matches(&w(&["headphones"]), false));
        let s51 = Speakers::surround(Layout::Surround51);
        assert!(s51.matches(&w(&["surround"]), false));
        assert!(s51.matches(&w(&["quad", "surround51"]), false));
        assert!(!s51.matches(&w(&["surround71"]), false));
        assert!(Speakers::matrix().matches(&w(&["matrix"]), false));
    }

    #[test]
    fn round_trip_through_alsoft_ini() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("alsoft.ini");
        for s in [
            Speakers::stereo(Listening::Auto, false),
            Speakers::stereo(Listening::Headphones, true),
            Speakers::stereo(Listening::Speakers, false),
            Speakers::surround(Layout::Quad),
            Speakers::surround(Layout::Surround71),
            Speakers::matrix(),
        ] {
            std::fs::write(&f, "[general]\nchannels=stereo\n# hrtf-mode = full\n").unwrap();
            s.write_alsoft(&f).unwrap();
            let back = Speakers::from_alsoft(&f).unwrap();
            assert_eq!(back.label(), s.label());
            assert_eq!(back.alsoft_values(), s.alsoft_values());
        }
        std::fs::write(&f, "[general]\n").unwrap();
        assert_eq!(Speakers::from_alsoft(&f), None);
    }
}
