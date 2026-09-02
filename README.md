# PlexTranscoderShim

PlexTranscoderShim is an unofficial Windows wrapper for Plex Media Server's
transcoder. Its argument-rewriting stage fails open: it can replace
quality-only rate control for selected hardware encoders with an explicit
target bitrate derived from Plex's own `-maxrate` value.

The original use case is Intel Quick Sync HEVC (`hevc_qsv`) producing remote
streams well above the requested bandwidth when Plex invokes it with `-q:N`.
For a configured encoder, the shim changes that output stream to constrained
VBR while passing the rest of Plex's command line through verbatim.

This project is not affiliated with or supported by Plex, Inc. Replacing a
file in the Plex installation directory is inherently unsupported. Read the
[rollback guide](docs/ROLLBACK.md) before installing.

## What it does

For an eligible output stream, this:

```text
-codec:0 hevc_qsv -q:0 20 -maxrate:0 10000k
```

becomes this with the default `bitrate_factor = 0.90`:

```text
-codec:0 hevc_qsv -b:0 9000k -maxrate:0 10000k
```

The rewrite is deliberately narrow:

- Only encoders listed in `codecs` are eligible.
- The output stream index must match the rate-control options.
- `-maxrate:N` must be present; otherwise the command is unchanged.
- Input-side decoder options before the selected output encoder are untouched.
- Invalid or unreadable configuration causes the original arguments to pass
  through unchanged.
- The real Plex transcoder's exit code and standard streams are preserved.

Fail-open applies to configuration and argument rewriting, not every possible
wrapper failure. If the shim itself cannot start, or the preserved native
transcoder is missing or cannot launch, the wrapper cannot recover playback.
The health checker and documented rollback procedure exist for those cases.

The shim also places itself and the real transcoder in a Windows Job Object so
the child should not be orphaned when Plex ends the wrapper. Job setup failure
is non-fatal.

## Requirements

- Plex Media Server on 64-bit Windows
- Windows PowerShell 5.1 or PowerShell 7
- The .NET Framework C# compiler included with Windows
- Administrator access for installation and removal

The current implementation is intended for Windows x64. It has no Linux,
macOS, Docker, or NAS install path.

## Build and test

From the repository root:

```powershell
.\scripts\Build.ps1
.\tests\Test-Rewrite.ps1
.\tests\Test-EndToEnd.ps1
.\tests\Test-Management.ps1
```

The executable and a working configuration are written to `dist\`. Generated
binaries are intentionally not committed; build them locally, download a
versioned archive from GitHub Releases, or use the artifact from a successful
GitHub Actions run.

The end-to-end test compiles a disposable fake transcoder and verifies child
argument forwarding, exit-code preservation, disabled and invalid-config
pass-through, missing-child behavior, concurrent logging, and Job Object child
cleanup. The management test exercises install, repair, enable/disable,
manifest creation, and full rollback under an isolated temporary directory.
Neither test touches the Plex installation.

## Install

First inspect [config/shim.ini.example](config/shim.ini.example). Then open an
Administrator PowerShell window in the repository and run:

```powershell
.\scripts\Build.ps1
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Status
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Install -StopPlex
```

`-StopPlex` explicitly authorizes the script to stop running Plex processes.
Without it, the script refuses to alter files while Plex is running. Start
Plex Media Server again after installation.

The installer:

1. Creates a timestamped backup and SHA-256 manifest under
   `%ProgramData%\PlexTranscoderShim\Backups`.
2. Preserves Plex's native executable as `Plex Transcoder Real.exe`.
3. Installs the shim as `Plex Transcoder.exe`.
4. Copies the example configuration only if `shim.ini` does not already exist.

Native files used for install, repair, and rollback must have a valid
`Plex, Inc.` Authenticode signature. If certificate validation is unavailable,
inspect the file first and use `-AllowUnverifiedNative` as an explicit override.

For a non-default Plex directory, add `-PlexDirectory 'D:\path\to\Plex Media Server'`
to management and health-check commands.

## Verify operation

Start one HEVC Quick Sync transcode, then run the read-only checker:

```powershell
.\scripts\Test-PlexTranscoderShim.ps1 -Hours 1
```

The checker confirms executable identity, preservation of the native
transcoder, configuration state, paired `IN`/`OUT` log entries, removal of the
quality option, and the observed bitrate ratio. Plex's own transcoder command
log is written before launch, so it cannot show the shim's post-launch rewrite.

Review actual playback quality and bandwidth before relying on the result.
Hardware, driver, media, subtitle, and Plex-version differences can all affect
transcoding behavior.

Before depending on a release, test the exact build with your Plex version and
GPU driver. The initial development system used Plex Media Server
`1.43.4.10903` on Windows 11; that is a compatibility data point, not a promise
that other or future versions use the same command-line format.

## Configuration

`shim.ini` is read on every invocation. Changes affect new transcodes without a
rebuild or Plex restart.

| Key | Default | Purpose |
| --- | --- | --- |
| `enabled` | `1` | Emergency pass-through switch; `0` disables rewriting. |
| `codecs` | `hevc_qsv` | Comma-separated eligible output encoders. |
| `bitrate_factor` | `0.90` | Target bitrate as a fraction of `-maxrate`; valid range `(0, 1]`. |
| `bufsize_factor` | `0` | Buffer as a multiple of `-maxrate`, from 0 through 10; `0` preserves Plex's value. |
| `priority` | blank | Optional child CPU priority; `realtime` is refused. |
| `extra` | blank | Raw extra arguments; `{i}` expands to the stream index. |
| `log` | `1` | Enables rewrite and warning logs. |
| `log_max_mb` | `5` | Log rollover threshold, from 1 through 1024 MB. |
| `logfile` | `%LOCALAPPDATA%\PlexTranscoderShim\shim.log` | Optional absolute log path; environment variables are expanded. |

Use `extra` only after testing the exact option with your encoder. It is
inserted as literal command-line text and can break a transcode if malformed.
Invalid Boolean values are rejected instead of being silently interpreted as
false.

## Disable, uninstall, and Plex updates

To stop rewriting new sessions immediately without replacing executables:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Disable
```

To restore Plex's native transcoder completely:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Uninstall -StopPlex
```

Plex updates may overwrite the active shim. Run `-Action Status` after every
Plex update. If the active and preserved executables are both native, rebuild
and run `-Action Repair -StopPlex`; this preserves the newly updated native
transcoder before reinstalling the shim. If the preserved executable is gone,
use `-Action Install -StopPlex` instead.

See [Rollback and recovery](docs/ROLLBACK.md) for the manual emergency process
and backup restoration. See [Troubleshooting](docs/TROUBLESHOOTING.md) for
common failures and log interpretation.

## Security and privacy

Command-line logs can contain local paths, media names, session identifiers,
and other private values. Common token-shaped query values are redacted on a
best-effort basis, but this is not a security boundary. Restrict access to the
log and sanitize it before sharing. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
