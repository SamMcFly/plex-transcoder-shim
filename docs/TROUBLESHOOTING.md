# Troubleshooting

## The script says Plex is running

Stop Plex yourself, or explicitly allow the management script to stop related
processes by adding `-StopPlex`. The script does not restart Plex afterward.

## A Plex update removed the shim

Check the current state:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Status
```

If both the active and preserved executables show as native, run:

```powershell
.\scripts\Build.ps1
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Repair -StopPlex
```

If the preserved executable is missing, use `Install` instead of `Repair`.
Never overwrite a newly updated native transcoder with an older preserved copy;
Plex's executable and codec bundle may be version-dependent.

## The health checker reports no recent activity

The shim logs only command lines it actually rewrites, plus warnings and
errors. Start a session that truly transcodes to a configured encoder. Direct
Play, Direct Stream, software encoding, and an unlisted encoder do not produce
an `IN`/`OUT` pair.

Also verify:

- `enabled = 1`
- `log = 1`
- `codecs` includes the encoder Plex selected
- `logfile`, if set, points to a writable directory
- `-maxrate:N` is present for the same output stream index

Run a wider check if the most recent qualifying transcode is older:

```powershell
.\scripts\Test-PlexTranscoderShim.ps1 -Hours 168
```

## Plex's log still shows `-q:N`

That is expected. Plex logs the command it intends to launch before the shim
sees it. The shim's `OUT` line is the post-rewrite command. Use the supplied
health checker instead of Plex's pre-launch command line to verify operation.

## A command passes through unchanged

Pass-through is intentional when:

- the shim is disabled;
- the output encoder is not in `codecs`;
- no matching `-maxrate:N` exists;
- configuration parsing or validation fails.

Configuration errors are logged as `ERROR (passing through unmodified)`. This
behavior protects playback, but it also means an invalid configuration silently
disables the desired rewrite unless logs or the checker are monitored.

## The real transcoder cannot be found

The shim requires `Plex Transcoder Real.exe` in the same directory. Return to a
known native state using [Rollback and recovery](ROLLBACK.md), or repair/reinstall
Plex Media Server. Do not copy an executable from an unrelated Plex version.

## Transcodes fail after adding `extra`

Set `extra =` to blank. Its content is inserted as raw command-line text, and
unsupported encoder arguments can make the real transcoder exit. `{i}` is the
only substitution performed.

## Logs are not created

With no `logfile` setting, the shim writes `shim.log` next to itself. Plex must
have write permission there. If that location is not writable, set an absolute
path in a directory writable by the Plex process. Logging failure never blocks
a transcode.

Treat logs as private. See [SECURITY.md](../SECURITY.md).

## Collect a useful problem report

Include:

- Windows version and Plex Media Server version
- GPU model and driver version
- relevant `shim.ini` values, with private paths removed
- output from `Test-PlexTranscoderShim.ps1`
- a small, sanitized pair of `IN` and `OUT` lines
- whether uninstalling the shim changes the problem

Do not post Plex tokens, API keys, private media paths, public IP addresses, or
full unsanitized command lines.
