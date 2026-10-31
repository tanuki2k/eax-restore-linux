# Troubleshooting

## Logs and bug reports

Every run is saved to a log file in `~/.local/state/eax-restore-linux/logs/`, and the script prints the path when it finishes. Each run gets its own timestamped file, and the newest 10 are kept. `latest.log` always points to the most recent one. Dev builds log separately, in `~/.local/state/eax-restore-linux/logs/dev/`.

The log has everything that was on screen, plus your answers to the prompts. It also records what helps with troubleshooting: your distro, kernel and Wine, winetricks and protontricks versions, the output of every Wine, winetricks and protontricks command the script ran, and a summary of the game it found, its prefix, the runner (Proton or Wine version), the architecture and the engine you chose.

If you'd rather not keep logs, set `EAX_RESTORE_NO_LOG=1`.

## DSOAL logging

When the install worked but the game doesn't sound right, DSOAL's own log tells you more. **Tools → [D]SOAL logging** adds `DSOAL_LOGLEVEL` and `DSOAL_LOGFILE` to the game's Steam launch options or Heroic environment variables. From then on DSOAL writes `dsoal.log` to the game folder every time the game starts.

It also adds `ALSOFT_LOGLEVEL=3` and `ALSOFT_LOGFILE`, so OpenAL Soft writes `openal.log` beside it. A game installed with OpenAL Soft alone has no DSOAL, so it only gets those two settings. The log shows the device OpenAL Soft opened, the extensions it found and any errors. It doesn't say which EAX version the game uses, because OpenAL Soft only logs EAX calls that fail, so a log without EAX lines doesn't mean EAX is off. With DSOAL, `dsoal.log` at level 4 lists every EAX call.

You choose how much it records:

| Level | What it logs | Downside |
| --- | --- | --- |
| Full (level 4) | Every EAX call the game makes, which shows which EAX version it really uses | The log grows fast and the game may stutter |
| Basic (level 3) | Start-up, and which EAX versions the game asks for | Less detail |

The level only applies to DSOAL's log. OpenAL Soft's is always level 3 (information, warnings and errors).

To turn it on at level 4 during an install instead, run the install with `EAX_RESTORE_DSOAL_LOG=1`.

Run the same menu item again to turn it off. Uninstalling turns it off too if you set the DLL override through the launcher. If you used the registry or set it by hand, turn logging off here first.

## Reporting a bug

If something goes wrong, please [open a bug report](https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md) and attach `~/.local/state/eax-restore-linux/logs/latest.log`.

> [!NOTE]
> The log includes local file paths, which contain your username. Feel free to redact it.
