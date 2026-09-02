# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this
repository when available. Do not open a public issue containing credentials,
Plex tokens, private media paths, or full command lines from a personal server.

## Trust and privilege model

The shim runs whenever Plex launches its transcoder and forwards arguments to
Plex's preserved native executable. Installation requires administrator rights
because it changes the Plex installation directory. Review the source and
management script before use, and build the executable yourself or verify a
published artifact's provenance.

The `extra` configuration value is trusted raw command-line input. Only an
administrator or the account that manages Plex should be able to modify
`shim.ini`.

## Log privacy

Rewrite logs may expose media names, local paths, stream metadata, session
identifiers, network locations, and arguments added by future Plex versions.
The shim performs best-effort redaction of common token and API-key query
patterns, but it cannot guarantee removal of every secret format.

Keep logs access-controlled, retain only what is needed, and sanitize excerpts
before sharing them. Set `log = 0` if command-line logging is unacceptable;
the activity portion of the health checker will then be unavailable.
