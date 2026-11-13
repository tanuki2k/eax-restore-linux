//! The real [`Host`] and [`UninstallHost`]: the running game is looked for
//! in `/proc`, the registry waits for wineserver, and the Wine side runs in
//! the game's prefix. Closing a launcher is the one thing left to the
//! caller, since it means asking the player.

use super::apply::Host;
use super::builds::Net;
use super::eax_unified::{self, Installer};
use super::launcher::target::Target;
use super::manifest::Companion;
use super::prefix;
use super::process;
use super::uninstall::{RegistryWork, UninstallHost};
use super::vcrun;
use super::wine::{self, Prefix, Runner};
use std::path::PathBuf;
use std::time::Duration;

pub struct SystemHost<'a> {
    pub prefix: Prefix,
    pub game_dir: PathBuf,
    /// The game's exe as its profile names it; empty when there's no profile.
    pub game_exe: String,
    /// How to run protontricks, for a companion app's prefix.
    pub protontricks: Vec<String>,
    pub net: &'a mut dyn Net,
    /// `~/.local/share/eax-restore-linux`.
    pub cache: PathBuf,
    pub eax_unified: Installer,
    /// Called before a launcher's settings file is changed: close it (asking
    /// the player first) and say whether it's closed.
    pub close_launcher: &'a mut dyn FnMut(&Target) -> bool,
}

impl Host for SystemHost<'_> {
    fn game_running(&mut self) -> bool {
        process::exe_running(&self.game_exe)
    }

    /// Wine keeps the registry in wineserver's memory and writes it back when
    /// it exits, which would undo an edit made meanwhile; while the game runs
    /// wineserver won't exit.
    fn registry_quiet(&mut self) -> bool {
        if self.game_running() {
            return false;
        }
        self.prefix.wait_for_wineserver();
        true
    }
}

impl UninstallHost for SystemHost<'_> {
    fn launcher_closed(&mut self, target: &Target) -> bool {
        (self.close_launcher)(target)
    }

    fn remove_registry(&mut self, work: &RegistryWork) -> bool {
        prefix::remove_registry(&self.prefix, &self.game_dir, work.com, work.dll.as_deref())
    }

    fn remove_vcrun(&mut self) {
        vcrun::uninstall(
            &self.prefix,
            &self.game_dir,
            &self.cache.join("vcrun2022"),
            self.net,
        );
    }

    fn remove_eax_unified(&mut self) -> bool {
        eax_unified::uninstall(&self.prefix, &self.eax_unified, Duration::from_secs(1))
    }

    /// A companion app's own prefix (DOOM 3's Resurrection of Evil): gone
    /// with the app when Steam deleted it, so there's then nothing to do.
    fn clean_companion(&mut self, c: &Companion, remove_vcrun: bool) {
        let Some(path) = wine::steam_prefix_for_appid(&self.protontricks, &c.app_id) else {
            return;
        };
        let p = Prefix {
            path,
            runner: Some(Runner::Protontricks {
                cmd: self.protontricks.clone(),
                app_id: c.app_id.clone(),
            }),
            log: self.prefix.log.clone(),
        };
        if c.registry_com || c.registry_override.is_some() {
            prefix::remove_registry(
                &p,
                &self.game_dir,
                c.registry_com,
                c.registry_override.as_deref(),
            );
        }
        if remove_vcrun {
            vcrun::uninstall(&p, &self.game_dir, &self.cache.join("vcrun2022"), self.net);
        }
    }
}
