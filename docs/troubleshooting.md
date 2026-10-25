# Troubleshooting

## Logs & bug reports

Every run is saved to a log file in `~/.local/state/eax-restore-linux/logs/`, and the script prints its path when the run finishes.

* Each run gets its own timestamped file (the newest 10 are kept).
* `latest.log` always points at the most recent one.
* Dev builds log separately, to `~/.local/state/eax-restore-linux/logs/dev/`.

The log contains everything shown on screen and your answers to the script's prompts, plus details for troubleshooting: your distro, kernel, and Wine/winetricks/protontricks versions, the output of the Wine, winetricks, and protontricks commands the script runs, and a summary of the detected game, prefix, runner (Proton/Wine version), architecture, and chosen engine.

## DSOAL logging

For problems with how a game *sounds* once it's running, DSOAL's own log helps more. **Tools → [D]SOAL logging** adds `DSOAL_LOGLEVEL` and `DSOAL_LOGFILE` to the game's Steam launch options or Heroic environment variables, so DSOAL writes `dsoal.log` to the game folder each time the game starts.

| Level | Logs | Catch |
| --- | --- | --- |
| **Full** (level 4) | Every EAX call the game makes, which shows which EAX version it actually uses | The log grows fast and the game may stutter |
| **Basic** (level 3) | Startup and which EAX versions the game asks for | Less detail |

Run the utility again to turn it off. Uninstalling the fix turns it off too when the DLL override was set through the launcher; if you used the registry or set it by hand, turn logging off here first.

## Reporting a bug

If something goes wrong, please [open a bug report](https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md) and attach `~/.local/state/eax-restore-linux/logs/latest.log`.

> [!NOTE]
> The log includes local file paths, which contain your username. You can redact them.
