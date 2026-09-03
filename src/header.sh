#!/usr/bin/env bash

# ==============================================================================
# DSOAL & OpenAL Soft Universal Installer for Linux
# ==============================================================================
#
# A streamlined Bash script designed to automate the restoration of EAX 3D
# audio in older Windows games running on Linux via Steam or Heroic.
#
# --- Features ---
# * Dual-Copy Architecture: Deploys DSOAL/OpenAL files to both the local game
#   folder and the Wine/Proton prefix system folders, with conflict backups
#   on both — not just the game folder.
#
# * Engine Choice: kcat's DSOAL + OpenAL Soft (translates DirectSound3D/EAX
#   to OpenAL), or a direct OpenAL Soft swap for games that call OpenAL
#   natively. EAX_RESTORE_DSOAL_PIN swaps in a frozen known-good DSOAL
#   revision when a rolling build regresses.
#
# * Recent Games: Remembers game folders you've used before and offers them
#   as a quick pick, without giving up the option to enter a new path.
#
# * Smart Detection: Opt-in auto-detection for Steam AppIDs and Heroic Wine
#   prefixes, plus an opt-in library scan that finds known EAX games already
#   installed via Steam or Heroic and lets you pick one instead of browsing.
#
# * Proton Detection: Identifies Proton runners even within Heroic environments.
#
# * Deep Validation: Confirms Heroic/GOG prefixes are initialised via drive_c,
#   and points you to launch the game first if the prefix isn't ready yet.
#
# * Architecture Detection: Scans the game's .exe files for 32-bit vs 64-bit
#   PE headers to auto-select the matching wrapper build, with a manual
#   fallback if detection is inconclusive.
#
# * Interactive Conflicts: Existing files are backed up (timestamped) before
#   being overwritten, and restored automatically on uninstall.
#
# * Install Manifest: Tracks exactly what each install deployed — files and
#   registry keys alike — so uninstall only ever removes what this script
#   actually put there, never guesses by filename, and safely no-ops if run
#   again on an already-uninstalled game.
#
# * Checksum Verification: Live verification against GitHub's published
#   digests for kcat's rolling builds, plus a pinned SHA256 for the optional
#   frozen fallback revision, with a clear prompt if a file can't be verified
#   either way.
#
# * Hardened Downloads: Fails loudly on bad HTTP responses, verifies zip
#   integrity before extracting, and preserves the existing cache instead of
#   wiping it on a failed download.
#
# * Pre-Flight Dependency Check: Verifies curl, unzip, file, protontricks,
#   winetricks, wine, and jq are available before touching the cache, and
#   offers to auto-install anything missing via your distro's package
#   manager (skipped in favour of Discover on SteamOS, per Safety Guards).
#
# * Advanced Tweaks: Optional EAX Unified dummies, COM registry routing,
#   expanded audio limits, and HRTF headphone output.
#
# * Auto-Overrides: Injects WINEDLLOVERRIDES natively into the Wine registry,
#   tracked so uninstall can clean it up automatically without re-prompting.
#
# * Hybrid Dependencies: Falls back to a direct Microsoft download for the
#   VC++ 2022 Redistributable when winetricks/protontricks fails, verifying
#   the actual runtime DLLs on disk rather than trusting exit codes. Uninstall
#   can offer to remove it again too, with a warning since a prefix may be
#   shared by other games or apps.
#
# * Safety Guards: Refuses to run as root or from Steam's Gaming Mode, and
#   won't auto-modify SteamOS's immutable filesystem.
#
# --- Environment Variables ---
# * EAX_RESTORE_SKIP_PREFLIGHT=1  Skips the pre-flight tool scan and its
#   auto-install prompts, trusting that curl, unzip, file, protontricks,
#   winetricks, and wine are already available. Speeds up repeat runs on a
#   machine you've already verified.
#
# * EAX_RESTORE_DSOAL_PIN=1  Installs a frozen, known-good kcat/dsoal build
#   (the revision pinned in the script, taken from kcat's "archive" release)
#   in place of the rolling latest-master. A break-glass lever for when a
#   daily build regresses a game — pairs the pinned DSOAL with the current
#   OpenAL Soft so only the one variable changes. Also selects the DSOAL
#   engine and skips the (i)nstall/(u)ninstall menu (goes straight to
#   install) and the engine-selection prompt.
#
# * EAX_RESTORE_VCRUN_ONLY=1  Skips the full install/uninstall flow and just
#   (re)installs the MS VC++ 2022 Redistributable into a game's prefix.
#   Useful if you skipped that step during a normal install and want to go
#   back for it without redoing everything else.
#
# * EAX_RESTORE_SKIP_CACHE_CHECK=1  Skips the REPOSITORY CACHE CHECK step
#   (the GitHub update check/download for DSOAL and OpenAL Soft), trusting
#   whatever's already in the local cache. Speeds up repeat runs on a
#   machine with a cache you know is current; if a needed engine build
#   isn't cached yet, deployment will fail later with nothing to install.
#
# * EAX_RESTORE_KNOWN_GAMES_FILE=/path/to/file.json  Uses a local file instead
#   of fetching known-eax-games.json from GitHub. For testing schema/data
#   edits to the database before they've been pushed to the branch it's
#   normally fetched from.
#
# --- License ---
# MIT License
# Copyright (c) 2026 Tanuki2k
# ==============================================================================
