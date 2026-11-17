//! The F2 settings screen: the player's defaults for new installs. Every
//! change is saved as soon as it's made.

use crate::build_choice::{BuildInfo, Comp};
use crate::panel::Opt;
use crate::prefs::{BuildPref, OverridePref, Prefs, SpeakerPref, VcPref};
use crate::theme;
use crate::ui::{boxed, gutter, MARGIN};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Wrap};
use ratatui::Frame;
use std::path::PathBuf;

/// The rows, in the order they're shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    DsoalBuild,
    OpenalBuild,
    Override,
    Speakers,
    Vcrun,
}

pub const FIELDS: [Field; 5] = [
    Field::DsoalBuild,
    Field::OpenalBuild,
    Field::Override,
    Field::Speakers,
    Field::Vcrun,
];

const RESET_TEXT: &str = "Every setting on this screen goes back to how it came.";
const RESET_ASK: &str = "Reset all settings to their defaults?";

fn opts(list: &[(&str, &str)]) -> Vec<Opt> {
    list.iter()
        .map(|(l, h)| Opt {
            label: (*l).into(),
            help: (*h).into(),
        })
        .collect()
}

type Info<'a> = Option<&'a BuildInfo>;

/// A build row's options: the shared list, keeping the saved choice listed.
fn build_list(comp: Comp, pref: &BuildPref, info: Info) -> Vec<crate::build_choice::BuildOpt> {
    crate::build_choice::options(comp, info, Some(&pref.0))
}

fn build_opts(comp: Comp, pref: &BuildPref, info: Info) -> Vec<Opt> {
    build_list(comp, pref, info)
        .into_iter()
        .map(|o| Opt {
            label: o.label,
            help: o.help,
        })
        .collect()
}

impl Field {
    pub fn title(self) -> &'static str {
        match self {
            Field::DsoalBuild => "DSOAL build",
            Field::OpenalBuild => "OpenAL Soft build",
            Field::Override => "DLL override",
            Field::Speakers => "Speakers",
            Field::Vcrun => "VC++ runtime",
        }
    }

    pub fn options(self, p: &Prefs, info: Info) -> Vec<Opt> {
        match self {
            Field::DsoalBuild => build_opts(Comp::Dsoal, &p.dsoal_build, info),
            Field::OpenalBuild => build_opts(Comp::Openal, &p.openal_build, info),
            Field::Override => opts(&[
                (
                    "Steam or Heroic launch options",
                    "Adds WINEDLLOVERRIDES to the game's launch options in Steam, or its environment variables in Heroic. A game from neither launcher gets it in its prefix's registry.",
                ),
                (
                    "The prefix's registry",
                    "Sets the override in the game's Wine prefix.",
                ),
                ("I'll set it myself", "Shows the line to add yourself."),
            ]),
            Field::Speakers => crate::panel::speaker_choices()
                .into_iter()
                .map(|(l, h, _)| Opt {
                    label: l.into(),
                    help: h.into(),
                })
                .collect(),
            Field::Vcrun => opts(&[
                (
                    "Use it if it's there",
                    "Tells Wine to use Microsoft's VC++ files when the prefix has them, and skips them when it doesn't.",
                ),
                (
                    "Install it if it's missing",
                    "Installs Microsoft's VC++ 2022 runtime into a prefix that doesn't have it.",
                ),
                ("Leave it alone", "Doesn't touch the VC++ runtime."),
            ]),
        }
    }

    pub fn get(self, p: &Prefs, info: Info) -> usize {
        let at = |comp, pref: &BuildPref| {
            build_list(comp, pref, info)
                .iter()
                .position(|o| o.key == pref.0)
                .unwrap_or(0)
        };
        match self {
            Field::DsoalBuild => at(Comp::Dsoal, &p.dsoal_build),
            Field::OpenalBuild => at(Comp::Openal, &p.openal_build),
            Field::Override => match p.over {
                OverridePref::LaunchOptions => 0,
                OverridePref::Registry => 1,
                OverridePref::Manual => 2,
            },
            Field::Speakers => p.speakers.index(),
            Field::Vcrun => match p.vcrun {
                VcPref::UseIfThere => 0,
                VcPref::InstallIfMissing => 1,
                VcPref::LeaveAlone => 2,
            },
        }
    }

    pub fn set(self, p: &mut Prefs, i: usize, info: Info) {
        let key = |comp, pref: &BuildPref| {
            build_list(comp, pref, info)
                .get(i)
                .map_or_else(BuildPref::default, |o| BuildPref(o.key.clone()))
        };
        match self {
            Field::DsoalBuild => p.dsoal_build = key(Comp::Dsoal, &p.dsoal_build),
            Field::OpenalBuild => p.openal_build = key(Comp::Openal, &p.openal_build),
            Field::Override => {
                p.over = [
                    OverridePref::LaunchOptions,
                    OverridePref::Registry,
                    OverridePref::Manual,
                ][i.min(2)];
            }
            Field::Speakers => {
                p.speakers = SpeakerPref::ALL[i.min(SpeakerPref::ALL.len() - 1)];
            }
            Field::Vcrun => {
                p.vcrun = [
                    VcPref::UseIfThere,
                    VcPref::InstallIfMissing,
                    VcPref::LeaveAlone,
                ][i.min(2)];
            }
        }
    }
}

pub struct PrefsScreen {
    pub prefs: Prefs,
    /// Where they're saved; None leaves them unsaved.
    path: Option<PathBuf>,
    /// A row, or `FIELDS.len()` for the Reset button.
    pub focus: usize,
    /// The open list of the focused row's options, and its highlight.
    pub list: Option<usize>,
    /// The first line of that list that shows, when it's too long to fit.
    list_top: std::cell::Cell<usize>,
    /// The reset's yes/no question is showing.
    pub asking: bool,
    /// Why the last save failed.
    pub error: Option<String>,
    pub closed: bool,
    /// Where the focused row's field was last drawn, for its dropdown.
    field: std::cell::Cell<Option<Rect>>,
    /// The build lists, while they're looked up, then once they're here.
    builds_rx: Option<std::sync::mpsc::Receiver<BuildInfo>>,
    pub build_info: Option<BuildInfo>,
}

/// Why the settings weren't saved, in words rather than an OS error number.
fn save_error(path: &std::path::Path, e: &std::io::Error) -> String {
    let why = match e.kind() {
        std::io::ErrorKind::PermissionDenied => "because permission was denied".to_string(),
        kind => format!("({kind})"),
    };
    format!("Couldn't save your settings to {} {why}.", path.display())
}

impl PrefsScreen {
    pub fn new(prefs: Prefs, path: Option<PathBuf>) -> Self {
        PrefsScreen {
            prefs,
            path,
            focus: 0,
            list: None,
            list_top: std::cell::Cell::new(0),
            asking: false,
            error: None,
            closed: false,
            field: std::cell::Cell::new(None),
            builds_rx: None,
            build_info: None,
        }
    }

    /// Looks the build lists up from GitHub while the screen is open.
    pub fn with_build_lookup(mut self, home: PathBuf) -> Self {
        self.builds_rx = Some(crate::build_choice::spawn(home));
        self
    }

    /// Takes the build lists once they've arrived.
    pub fn tick(&mut self) {
        if let Some(rx) = &self.builds_rx {
            match rx.try_recv() {
                Ok(info) => {
                    self.build_info = Some(info);
                    self.builds_rx = None;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.builds_rx = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
    }

    pub fn waiting(&self) -> bool {
        self.builds_rx.is_some()
    }

    fn save(&mut self) {
        let Some(path) = &self.path else { return };
        self.error = self.prefs.save_to(path).err().map(|e| save_error(path, &e));
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        if self.asking {
            match key.code {
                KeyCode::Char('y' | 'Y') => {
                    self.asking = false;
                    self.prefs = Prefs::default();
                    self.save();
                }
                KeyCode::Char('n' | 'N') | KeyCode::Esc => self.asking = false,
                _ => {}
            }
            return;
        }
        if let Some(sel) = self.list {
            let field = FIELDS[self.focus];
            let len = field.options(&self.prefs, self.build_info.as_ref()).len();
            match key.code {
                KeyCode::Up => self.list = Some(sel.saturating_sub(1)),
                KeyCode::Down => self.list = Some((sel + 1).min(len - 1)),
                KeyCode::PageUp => self.list = Some(sel.saturating_sub(5)),
                KeyCode::PageDown => self.list = Some((sel + 5).min(len - 1)),
                KeyCode::Home => self.list = Some(0),
                KeyCode::End => self.list = Some(len - 1),
                KeyCode::Esc => self.list = None,
                KeyCode::Enter => {
                    self.list = None;
                    let info = self.build_info.clone();
                    if field.get(&self.prefs, info.as_ref()) != sel {
                        field.set(&mut self.prefs, sel, info.as_ref());
                        self.save();
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Esc | KeyCode::F(2) => self.closed = true,
            KeyCode::Up => self.focus = self.focus.saturating_sub(1),
            KeyCode::Down | KeyCode::Tab => self.focus = (self.focus + 1).min(FIELDS.len()),
            KeyCode::Home => self.focus = 0,
            KeyCode::End => self.focus = FIELDS.len(),
            KeyCode::Enter => match FIELDS.get(self.focus) {
                Some(f) => {
                    self.list_top.set(0);
                    self.list = Some(f.get(&self.prefs, self.build_info.as_ref()));
                }
                None => self.asking = true,
            },
            _ => {}
        }
    }

    pub fn keys(&self) -> Vec<(&'static str, &'static str)> {
        if self.asking {
            vec![("y", "reset"), ("n", "keep them")]
        } else if self.list.is_some() {
            vec![("↑/↓", "choose"), ("Enter", "pick"), ("Esc", "keep it")]
        } else {
            vec![("↑/↓", "move"), ("Enter", "change"), ("Esc", "back")]
        }
    }

    pub fn draw(&self, f: &mut Frame, area: Rect) {
        // Inside the border and the margin of a pop-up as wide as the help.
        let width = usize::from(crate::ui::POPUP_W.min(area.width).saturating_sub(6)).max(1);
        let mut lines: Vec<Line> = crate::settings::wrap(
            "These are your defaults for new installs. A game that already has the fix keeps what it has.",
            width,
            "",
        )
        .into_iter()
        .map(|l| Line::from(Span::styled(l, theme::dim())))
        .collect();
        lines.push(Line::from(""));

        let title_w = FIELDS
            .iter()
            .map(|f| f.title().chars().count())
            .max()
            .unwrap_or(0)
            + 2;
        let field_w = FIELDS
            .iter()
            .flat_map(|f| f.options(&self.prefs, self.build_info.as_ref()))
            .map(|o| o.label.chars().count())
            .max()
            .unwrap_or(10)
            .min(width.saturating_sub(title_w + 8).max(6));
        // The focused row's line and the field's width, placed once the
        // pop-up's position is known.
        let mut field_at = None;
        for (i, field) in FIELDS.iter().enumerate() {
            let sel = self.focus == i;
            let info = self.build_info.as_ref();
            let options = field.options(&self.prefs, info);
            let value = &options[field.get(&self.prefs, info)].label;
            let value: String = if value.chars().count() > field_w {
                value
                    .chars()
                    .take(field_w.saturating_sub(1))
                    .collect::<String>()
                    + "…"
            } else {
                value.clone()
            };
            let pad = field_w.saturating_sub(value.chars().count());
            let bg = if sel {
                Style::new().bg(theme::SELECT_BG)
            } else {
                Style::new()
            };
            let frame = Style::new().fg(theme::LABEL);
            let name = format!("{:<title_w$}", field.title());
            if sel {
                field_at = Some(lines.len() as u16);
            }
            lines.push(
                Line::from(vec![
                    gutter(sel),
                    Span::styled(
                        name,
                        if sel {
                            Style::new().fg(theme::SELECT_TEXT)
                        } else {
                            Style::new()
                        },
                    ),
                    Span::styled("[ ", frame),
                    Span::raw(value),
                    Span::raw(" ".repeat(pad)),
                    Span::styled(" ▾", if sel { theme::key() } else { frame }),
                    Span::styled(" ]", frame),
                ])
                .style(bg),
            );
        }
        lines.push(Line::from(""));
        let on_reset = self.focus == FIELDS.len();
        let style = if on_reset {
            Style::new()
                .fg(theme::SELECT_TEXT)
                .bg(theme::SELECT_BAR)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(theme::LABEL)
        };
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled("[ Reset to defaults ]", style),
        ]));
        lines.push(Line::from(""));
        // What the focused row's value means, or what Reset does.
        let help = match FIELDS.get(self.focus) {
            Some(field) => {
                let info = self.build_info.as_ref();
                field.options(&self.prefs, info)[field.get(&self.prefs, info)]
                    .help
                    .clone()
            }
            None => "Puts every setting back to how it came.".into(),
        };
        lines.extend(
            crate::settings::wrap(&help, width, "")
                .into_iter()
                .map(|l| Line::from(Span::styled(l, theme::dim()))),
        );
        if let Some(e) = &self.error {
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(e.clone(), theme::label())));
        }
        let popup = crate::ui::centred_popup(area, lines.len());
        f.render_widget(Clear, popup);
        let block = boxed("Settings").padding(MARGIN);
        let inner = block.inner(popup);
        f.render_widget(block, popup);
        f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
        self.field.set(field_at.map(|row| {
            Rect::new(
                inner.x + 2 + title_w as u16,
                inner.y + row,
                (field_w + 6) as u16,
                1,
            )
        }));

        if let (Some(sel), Some(field)) = (self.list, FIELDS.get(self.focus)) {
            crate::panel::view::draw_dropdown(
                f,
                field.title(),
                &field.options(&self.prefs, self.build_info.as_ref()),
                (field.get(&self.prefs, self.build_info.as_ref()), sel),
                self.field.get(),
                area,
                &self.list_top,
            );
        }
        if self.asking {
            crate::panel::view::draw_question(f, RESET_TEXT, RESET_ASK, area);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::crossterm::event::KeyModifiers;
    use ratatui::Terminal;

    fn key(c: KeyCode) -> KeyEvent {
        KeyEvent::new(c, KeyModifiers::NONE)
    }

    fn screen(s: &PrefsScreen) -> String {
        let mut t = Terminal::new(TestBackend::new(100, 40)).unwrap();
        t.draw(|f| s.draw(f, f.area())).unwrap();
        let buf = t.backend().buffer().clone();
        (0..40)
            .map(|y| (0..100).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_failed_save_says_why_in_words() {
        let e = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert_eq!(
            save_error(std::path::Path::new("/c/tui.json"), &e),
            "Couldn't save your settings to /c/tui.json because permission was denied."
        );
    }

    #[test]
    fn every_field_round_trips_each_option() {
        for field in FIELDS {
            for i in 0..field.options(&Prefs::default(), None).len() {
                let mut p = Prefs::default();
                field.set(&mut p, i, None);
                assert_eq!(field.get(&p, None), i, "{field:?} option {i}");
            }
        }
        // The shipped defaults: Latest numbered builds (after Latest rolling
        // options), the first of the rest, and stereo that detects.
        let p = Prefs::default();
        let firsts: Vec<usize> = FIELDS.iter().map(|f| f.get(&p, None)).collect();
        assert_eq!(firsts, [1, 1, 0, SpeakerPref::Auto.index(), 0]);
    }

    #[test]
    fn shows_five_rows_and_a_reset_and_saves_each_change() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("eax-restore-linux/tui.json");
        let mut s = PrefsScreen::new(Prefs::default(), Some(file.clone()));
        let text = screen(&s);
        for f in FIELDS {
            assert!(text.contains(f.title()), "{text}");
        }
        assert!(text.contains("[ Reset to defaults ]"));
        assert!(text.contains("defaults for new installs"));

        // Latest rolling for DSOAL: picked from its dropdown and saved at once.
        s.handle_key(key(KeyCode::Enter));
        assert!(screen(&s).contains("─ DSOAL build ─"), "{}", screen(&s));
        s.handle_key(key(KeyCode::Up));
        s.handle_key(key(KeyCode::Enter));
        let rolling = BuildPref("rolling".into());
        assert_eq!(s.prefs.dsoal_build, rolling);
        assert_eq!(Prefs::load_from(&file).dsoal_build, rolling);

        // The list from GitHub adds every build under the two.
        s.build_info = Some(crate::build_choice::BuildInfo {
            catalog: crate::engine::builds::Catalog {
                dsoal: vec!["r697".into(), "r696".into()],
                openal: Vec::new(),
            },
            ..Default::default()
        });
        s.handle_key(key(KeyCode::Enter));
        assert!(screen(&s).contains("r696"), "{}", screen(&s));
        s.handle_key(key(KeyCode::End));
        s.handle_key(key(KeyCode::Esc));

        // Reset asks first; n keeps them, y puts the shipped ones back.
        s.handle_key(key(KeyCode::End));
        s.handle_key(key(KeyCode::Enter));
        assert!(screen(&s).contains(RESET_ASK));
        s.handle_key(key(KeyCode::Char('n')));
        assert_eq!(s.prefs.dsoal_build, rolling);
        s.handle_key(key(KeyCode::Enter));
        s.handle_key(key(KeyCode::Char('y')));
        assert_eq!(s.prefs, Prefs::default());
        assert_eq!(Prefs::load_from(&file), Prefs::default());

        s.handle_key(key(KeyCode::Esc));
        assert!(s.closed);
    }
}
