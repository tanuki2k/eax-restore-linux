//! Stamps the build number: the commit count on the branch, so the same
//! commit gets the same number on any machine with its full history (CI's
//! checkout needs `fetch-depth: 0`, or a shallow clone counts 1). A build from
//! a tree with uncommitted changes is marked, and a build with no git (a
//! source tarball) has no number.

use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn main() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    // A new commit, a checkout or a staged change gives a new number or mark.
    for p in ["HEAD", "index", "logs/HEAD"] {
        if let Some(path) = git(dir, &["rev-parse", "--git-path", p]) {
            let path = dir.join(path);
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
    println!("cargo:rerun-if-env-changed=EAX_RESTORE_BUILD");
    // CI or a packager can hand the number in.
    let number = std::env::var("EAX_RESTORE_BUILD")
        .ok()
        .filter(|n| n.parse::<u32>().is_ok())
        .or_else(|| git(dir, &["rev-list", "--count", "HEAD"]));
    if let Some(n) = number {
        println!("cargo:rustc-env=EAX_RESTORE_BUILD={n}");
        let dirty = git(dir, &["status", "--porcelain", "--untracked-files=no"])
            .is_some_and(|s| !s.is_empty());
        if dirty {
            println!("cargo:rustc-env=EAX_RESTORE_BUILD_DIRTY=1");
        }
    }
}
