# Rollback and recovery

Read this page before installation. The normal uninstall is transactional at
the file-copy level, records SHA-256 hashes, and saves the current state before
changing it. The manual procedure exists for cases where PowerShell or the
management script is unavailable.

## Fastest safe response: disable rewriting

This retains the shim but passes all arguments through unchanged for new
transcodes:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Disable
```

Existing transcodes are not changed. To restore rewriting later:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Enable
```

## Normal full rollback

Open PowerShell as Administrator from the repository root:

```powershell
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Status
.\scripts\Manage-PlexTranscoderShim.ps1 -Action Uninstall -StopPlex
```

The script refuses to proceed unless all of these are true:

- The active `Plex Transcoder.exe` identifies as `PlexTranscoderShim`.
- `Plex Transcoder Real.exe` exists and identifies as a native executable.
- The preserved native executable has a valid `Plex, Inc.` Authenticode
  signature, unless `-AllowUnverifiedNative` was explicitly supplied.
- Plex is stopped, or `-StopPlex` was explicitly supplied.

It backs up the current state, restores the preserved native executable to
Plex's active path, removes the redundant preserved copy, and leaves
`shim.ini` and `shim.log` for diagnosis. Start Plex Media Server afterward and
test local and remote playback.

## Manual emergency rollback

Use this only when the management script cannot run.

1. Stop Plex Media Server and all Plex transcoder processes.
2. Open the Plex installation directory, normally
   `C:\Program Files\Plex\Plex Media Server`.
3. Confirm that `Plex Transcoder Real.exe` exists and is substantially larger
   than the small managed shim. Do not delete or replace anything until this
   file has been verified.
4. Rename `Plex Transcoder.exe` to `PlexTranscoderShim.disabled.exe`.
5. Rename `Plex Transcoder Real.exe` to `Plex Transcoder.exe`.
6. Start Plex Media Server and test playback.

File size is only a useful emergency clue, not proof of identity. A stronger
check in PowerShell is:

```powershell
try {
    [Reflection.AssemblyName]::GetAssemblyName(
        'C:\Program Files\Plex\Plex Media Server\Plex Transcoder Real.exe'
    ).Name
} catch {
    'native executable'
}
```

The preserved Plex executable should report `native executable`. If it reports
`PlexTranscoderShim`, stop: the original is not in the expected location. Also
verify its signer before restoring it:

```powershell
Get-AuthenticodeSignature `
    'C:\Program Files\Plex\Plex Media Server\Plex Transcoder Real.exe' |
    Select-Object Status,@{Name='Signer';Expression={$_.SignerCertificate.Subject}}
```

The expected status is `Valid` and the signer should identify `Plex, Inc.`.

## Restore from an automatic backup

Backups are stored by default under:

```text
C:\ProgramData\PlexTranscoderShim\Backups\YYYYMMDD-HHMMSS-reason
```

Each directory contains the files that existed immediately before the change
and a `manifest.json` with original paths, sizes, timestamps, and SHA-256
hashes.

1. Stop Plex.
2. Choose the newest backup from before the unwanted change.
3. Read `manifest.json`; do not assume the newest folder contains a native
   active transcoder.
4. Verify a restored file after copying it:

   ```powershell
   Get-FileHash 'C:\Program Files\Plex\Plex Media Server\Plex Transcoder.exe' -Algorithm SHA256
   ```

5. Compare the result with the matching `SHA256` entry in the manifest.
6. Start Plex and test playback.

If the backup contains both a shim at the active path and a native
`Plex Transcoder Real.exe`, use the native file for a full rollback.

## After a Plex update

A Plex update can create either of these states:

| Active executable | Preserved executable | Correct action |
| --- | --- | --- |
| shim | native | No repair needed; run the health check. |
| native | native | Build, then run `-Action Repair -StopPlex`. |
| native | missing | Build, then run `-Action Install -StopPlex`. |
| shim | missing or shim | Do not modify files; restore a verified native file or reinstall Plex. |

`Repair` is specifically for the second row. It backs up both versions, copies
Plex's newly updated active transcoder over the stale preserved version, and
then reinstalls the shim.

When no verified native transcoder can be recovered, reinstall or repair Plex
Media Server using Plex's installer before considering another shim install.
