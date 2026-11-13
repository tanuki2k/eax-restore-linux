//! Whether a game is running, from `/proc`. A port of `game_exe_running` in
//! `src/game-config.sh`.

use std::collections::HashSet;
use std::path::Path;

fn parent_of(proc_root: &Path, pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(proc_root.join(pid.to_string()).join("stat")).ok()?;
    // The name in brackets can hold spaces; the fields after it can't.
    let after = &stat[stat.rfind(')')? + 1..];
    after.split_whitespace().nth(1)?.parse().ok()
}

/// This process and its ancestors, which a check must not count: a shell
/// whose command line merely mentions the exe isn't the game.
fn own_tree(proc_root: &Path, me: u32) -> HashSet<u32> {
    let mut ours = HashSet::new();
    let mut p = me;
    while p > 1 && ours.insert(p) {
        p = parent_of(proc_root, p).unwrap_or(1);
    }
    ours
}

/// True when `cmdline` (arguments joined by spaces) names the exe as a path:
/// after a `\` or `/`, then a space or the end. Ignores case, as Windows does.
fn names_exe(cmdline: &str, exe: &str) -> bool {
    let line = cmdline.to_lowercase();
    let exe = exe.to_lowercase();
    let mut from = 0;
    while let Some(at) = line[from..].find(&exe) {
        let start = from + at;
        let end = start + exe.len();
        let before = line[..start].chars().next_back();
        let after = line[end..].chars().next();
        if matches!(before, Some('\\' | '/')) && matches!(after, None | Some(' ')) {
            return true;
        }
        from = start + 1;
        while !line.is_char_boundary(from) {
            from += 1;
        }
    }
    false
}

/// True while a process outside this program's own tree, and not one it
/// started, has the game's exe (the profile's `exe`) on its command line.
/// Wine and Proton keep the Windows path there.
pub fn exe_running(exe: &str) -> bool {
    exe_running_in(Path::new("/proc"), std::process::id(), exe)
}

fn exe_running_in(proc_root: &Path, me: u32, exe: &str) -> bool {
    if exe.is_empty() {
        return false;
    }
    let ours = own_tree(proc_root, me);
    let Ok(entries) = std::fs::read_dir(proc_root) else {
        return false;
    };
    entries.flatten().any(|e| {
        let Some(pid) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
            return false;
        };
        if ours.contains(&pid) {
            return false;
        }
        let Ok(raw) = std::fs::read(e.path().join("cmdline")) else {
            return false;
        };
        let cmdline = String::from_utf8_lossy(&raw)
            .trim_end_matches('\0')
            .replace('\0', " ");
        if !names_exe(&cmdline, exe) {
            return false;
        }
        // A child of this program (a shell it started) isn't the game either.
        let mut p = pid;
        while p > 1 {
            if p == me {
                return false;
            }
            p = parent_of(proc_root, p).unwrap_or(1);
        }
        true
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exe_names() {
        assert!(names_exe(
            "Z:\\Games\\Quake4\\Quake4.exe +set x",
            "quake4.exe"
        ));
        assert!(names_exe("/home/u/Games/Q/Quake4.EXE", "Quake4.exe"));
        assert!(!names_exe("Z:\\Games\\NotQuake4.exe", "Quake4.exe"));
        assert!(!names_exe("Z:\\Games\\Quake4.exe.bak", "Quake4.exe"));
        assert!(!names_exe("Quake4.exe", "Quake4.exe"));
    }

    #[test]
    fn sees_another_process_but_not_its_own_children() {
        // A child of this process whose command line names the exe. The
        // "; :" keeps the shell from replacing itself with sleep, which
        // would drop the name from its command line.
        let marker = format!("Z:\\eax-restore-test-{}\\Game.exe", std::process::id());
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg("sleep 5; :")
            .arg(&marker)
            .spawn()
            .unwrap();
        // Give it a moment to start.
        let cmdline = std::path::PathBuf::from(format!("/proc/{}/cmdline", child.id()));
        for _ in 0..100 {
            if std::fs::read(&cmdline).is_ok_and(|c| c.windows(8).any(|w| w == b"Game.exe")) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let ours = own_tree(Path::new("/proc"), std::process::id());
        assert!(!ours.contains(&child.id()));
        assert!(!exe_running_in(
            Path::new("/proc"),
            std::process::id(),
            &format!("eax-restore-test-{}\\Game.exe", std::process::id())
        ));
        // Seen from outside this process's tree, the same process counts.
        let name = format!("eax-restore-test-{}\\Game.exe", std::process::id());
        assert!(exe_running_in(Path::new("/proc"), 1, &name));
        let _ = child.kill();
        let _ = child.wait();
    }
}
