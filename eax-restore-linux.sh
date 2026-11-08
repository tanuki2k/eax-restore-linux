#!/usr/bin/env bash
# This file is only a pointer. The EAX Restore script is published as a release
# asset, and this small script exists so a launcher or `curl` command saved from
# 0.28.x (which fetched this file from the main branch) keeps working. It
# downloads the latest release, checks it against the release's .sha256, and runs
# it. New downloads should use the release link in the README instead.

RELEASE_URL="https://github.com/tanuki2k/eax-restore-linux/releases/latest/download"

work="$(mktemp -d)" || { echo "Couldn't make a temporary folder to download the script into."; exit 1; }
trap 'rm -rf "$work"' EXIT

if ! curl -fsSL --connect-timeout 60 --max-time 300 "$RELEASE_URL/eax-restore-linux.sh" -o "$work/eax-restore-linux.sh" \
    || ! curl -fsSL --connect-timeout 60 --max-time 60 "$RELEASE_URL/eax-restore-linux.sh.sha256" -o "$work/eax-restore-linux.sh.sha256"; then
    echo "Something went wrong downloading the script. Please check your internet connection, or report this if it persists."
    exit 1
fi

expected="$(awk '{ print $1; exit }' "$work/eax-restore-linux.sh.sha256")"
actual="$(sha256sum "$work/eax-restore-linux.sh" | awk '{ print $1 }')"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "The downloaded script didn't match its checksum, so it wasn't run. Please try again, or report this if it persists."
    exit 1
fi

bash "$work/eax-restore-linux.sh" "$@"
