//! Where the launchers keep their files: `xdg_home`, `steam_roots` and
//! `heroic_roots` from `src/common.sh` and `src/detection.sh`. Every function
//! takes `home` so tests can use a fake one.

use std::path::{Path, PathBuf};

/// `$XDG_DATA_HOME` (`data`) or `$XDG_CONFIG_HOME`, else its default under
/// `home`. A relative value is ignored, as the XDG spec says. The variables
/// only count for the real home: a fake one in a test gets the defaults, as
/// the script does there, since its `$HOME` is the fake one too.
pub fn xdg_home(home: &Path, data: bool) -> PathBuf {
    let (var, default) = if data {
        ("XDG_DATA_HOME", ".local/share")
    } else {
        ("XDG_CONFIG_HOME", ".config")
    };
    let real_home = std::env::var_os("HOME").map(PathBuf::from);
    if real_home.as_deref() == Some(home) {
        if let Some(v) = std::env::var_os(var)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
        {
            let s = v.to_string_lossy();
            return PathBuf::from(s.strip_suffix('/').unwrap_or(&s));
        }
    }
    home.join(default)
}

/// Every Steam install present, each resolved through links: native first,
/// then Flatpak (its current and older data layouts), then Snap.
pub fn steam_roots(home: &Path) -> Vec<PathBuf> {
    let groups: [&[&str]; 3] = [
        &[".local/share/Steam", ".steam/steam"],
        &[
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/data/Steam",
        ],
        &[
            "snap/steam/common/.local/share/Steam",
            "snap/steam/common/.steam/steam",
        ],
    ];
    groups
        .iter()
        .filter_map(|g| {
            g.iter()
                .map(|d| home.join(d))
                .find(|d| d.join("steamapps").is_dir())
        })
        .map(|d| std::fs::canonicalize(&d).unwrap_or(d))
        .collect()
}

/// Heroic's config folders, native then Flatpak, whether or not they exist.
pub fn heroic_dirs(home: &Path) -> [PathBuf; 2] {
    [
        xdg_home(home, false).join("heroic"),
        home.join(".var/app/com.heroicgameslauncher.hgl/config/heroic"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snap_steam_is_found_after_the_others() {
        let t = tempfile::tempdir().unwrap();
        let home = t.path();
        for d in [
            ".local/share/Steam/steamapps",
            "snap/steam/common/.local/share/Steam/steamapps",
        ] {
            std::fs::create_dir_all(home.join(d)).unwrap();
        }
        let home = std::fs::canonicalize(home).unwrap();
        assert_eq!(
            steam_roots(&home),
            [
                home.join(".local/share/Steam"),
                home.join("snap/steam/common/.local/share/Steam")
            ]
        );
    }

    #[test]
    fn a_fake_home_gets_the_default_folders() {
        let home = Path::new("/nowhere/home");
        assert_eq!(xdg_home(home, true), home.join(".local/share"));
        assert_eq!(heroic_dirs(home)[0], home.join(".config/heroic"));
    }
}
