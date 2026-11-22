//! The TUI's build number, stamped by `build.rs`: the commit count on its
//! branch. It stands in for a version number in the bottom bar, the run log
//! and the update check.

/// The commit count, or none for a build with no git.
pub const BUILD: Option<&str> = option_env!("EAX_RESTORE_BUILD");

/// Built from a tree with uncommitted changes.
pub const DIRTY: bool = option_env!("EAX_RESTORE_BUILD_DIRTY").is_some();

pub fn number() -> Option<u32> {
    BUILD.and_then(|n| n.parse().ok())
}

/// "build 1842", "dev build 1842 (modified)", "local build".
pub fn label() -> String {
    label_for(number(), DIRTY, crate::fetch::CHANNEL == "dev")
}

pub fn label_for(build: Option<u32>, dirty: bool, dev: bool) -> String {
    let Some(n) = build else {
        return "local build".into();
    };
    let dev = if dev { "dev " } else { "" };
    let modified = if dirty { " (modified)" } else { "" };
    format!("{dev}build {n}{modified}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(label_for(Some(1842), false, false), "build 1842");
        assert_eq!(label_for(Some(1842), false, true), "dev build 1842");
        assert_eq!(label_for(Some(7), true, true), "dev build 7 (modified)");
        assert_eq!(label_for(None, true, true), "local build");
    }

    #[test]
    fn this_build_is_stamped_with_the_commit_count() {
        // The tests run from a git checkout; a shallow one (the TUI
        // workflow's) counts only what it has, so compare with git itself.
        let count = std::process::Command::new("git")
            .args([
                "-C",
                env!("CARGO_MANIFEST_DIR"),
                "rev-list",
                "--count",
                "HEAD",
            ])
            .output()
            .ok()
            .and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .parse::<u32>()
                    .ok()
            });
        if std::env::var("EAX_RESTORE_BUILD").is_err() {
            assert_eq!(number(), count);
        }
    }
}
