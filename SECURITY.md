# Security Policy

## Supported Versions

Agent Usage Bar is currently prerelease software. Security fixes are applied to
the latest release and the current `main` branch. Older prerelease builds may
not receive backports.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting from the repository's Security tab.

Do not include credentials, tokens, private account data, or exploitable details
in a public issue. If private reporting is unavailable, open a public issue
requesting a private contact channel without including vulnerability details.

This is a personal open-source project with no guaranteed response time or bug
bounty. Reports will be handled on a best-effort basis.

## System and Scope

Agent Usage Bar is a local macOS menu-bar application that displays Claude and
Codex subscription usage.

Security-sensitive components include:

- the fixed Claude Code `/usage` subprocess and its human-text parser;
- the Codex App Server subprocess and JSON-RPC/JSONL parser;
- executable-path validation and subprocess lifecycle management;
- cached usage snapshots and application preferences;
- build, signing, packaging, and release scripts.

## Threat Model and Trust Boundaries

Subprocess output, App Server messages, fixture files, and
configured executable paths must be treated as untrusted input.

Claude Code may include private local activity statistics in `/usage` output, and
raw provider responses are sensitive even though the app needs only two usage
lines. Authentication must remain inside each official CLI process.

A process already executing as the same macOS user may have substantial access
to that user's files and Keychain tools. This does not excuse Agent Usage Bar
from introducing additional credential exposure, command injection, unsafe
logging, or unintended account operations.

## Security Invariants

The following properties must remain true:

- Credentials are never read, logged, displayed, committed, or persisted by
  Agent Usage Bar. Authentication remains inside storage managed by each
  selected provider CLI.
- The app never reads, writes, or deletes Claude Code Keychain items.
- The app never reads Codex authentication files, session JSONL, SQLite
  databases, or caches.
- Provider operations remain account-read-only. The app must not log in, log
  out, purchase credits, consume reset credits, send account email, or modify
  provider settings.
- Claude execution uses one fixed, shell-free, read-only `/usage` argument list.
- Codex JSON-RPC methods remain closed and allow-listed.
- Subprocesses are started directly without a shell. The app terminates only
  subprocess instances that it created and still owns.
- A kernel-managed, per-user exclusive lock must atomically select one Agent
  Usage Bar instance before providers are created. A duplicate launch must
  yield without guessing ownership from PID ordering or terminating a peer
  application merely because it has the same bundle identifier.
- Every Claude and Codex subprocess runs from a new empty, local, non-symlink,
  mode-0700 temporary directory with matching `PWD`. Failure to create or
  validate that directory must fail the query; it must never fall back to `/`,
  the user's home directory, an app location, or a user project.
- Raw credentials and raw provider responses are not stored as diagnostics or
  test fixtures. The optional local error history stores only an app-generated
  timestamp, provider enum, and closed app-authored error category. It must not
  persist `UsageError` associated strings, JSON keys, RPC messages, subprocess
  output, executable paths, or arbitrary provider metadata.
- Malformed or unknown input fails safely and must not be presented as zero
  usage or current data.
- Provider-controlled display metadata and persisted snapshots have explicit
  byte and character-safety bounds before they can reach UI or restored state.
- Codex stdout enters one ordered consumer through a bounded ingress before
  JSONL parsing. Queued bytes and each JSONL line (including its unfinished tail) have an
  independent 4 MB limit; overflow discards only the exact owned connection.
- Rate limiting and retry instructions are bounded and must not create an
  uncontrolled request loop.
- Shared Xcode configuration, CI, fixtures, and documentation must not contain
  personal signing identifiers or secrets. Release packaging must never auto-select
  a machine identity; a future Developer ID signer is allowed only when the maintainer
  explicitly approves that public certificate identity and verifies the final artifact.

## Reportable Findings

Examples include:

- credential or raw-response disclosure through logs, UI, files, crashes, or
  subprocess output;
- command, argument, path, URL, header, or JSON-RPC injection;
- unintended account mutation or bypass of the read-only provider boundary;
- termination or control of unrelated Claude, Codex, or user processes;
- remotely reachable crashes, memory exhaustion, or unsafe parsing;
- committed secrets, real credentials, private account data, or signing keys;
- release artifacts whose source, checksum, signature, or documented identity
  does not match the release commit;
- a regression that silently changes unavailable or malformed data into a
  trusted usage value.

Severity depends on reachability and impact. Credential disclosure, account
mutation, or remote code execution is high impact. Issues requiring prior code
execution as the same macOS user may have lower incremental impact, but remain
reportable when this app creates a new exposure or broadens access.

## Accepted Risks and Exclusions

The following are documented product decisions and are not vulnerabilities by
themselves:

- Claude usage is obtained from the official CLI command, but the two usage
  figures are embedded in human-readable `result` text rather than a stable
  field schema. Compatibility breakage or upstream rate limiting alone is not
  a security finding; unsafe fallback, command expansion, or private-output
  disclosure remains reportable.
- Claude Code may answer `/usage` from its own local cache when offline. A stale
  but still-current-window reading is a documented product limitation, not a
  credential exposure.
- Public builds are not Apple-notarized. Gatekeeper requiring manual approval is
  expected. A misleading signature, checksum mismatch, or tampered artifact is
  still reportable.
- The repo-local packaged transaction, candidate manifest, checksum, and ad-hoc
  signature are defense-in-depth against mistakes and partial replacement. A
  same-user actor who can rewrite the repository and all local release evidence
  is outside the publisher-authentication guarantee until an external signing
  or trusted digest channel is adopted.
- The app is not currently sandboxed. The absence of App Sandbox alone is a
  known limitation; concrete unintended file, credential, network, or process
  access remains reportable.
- Unsupported provider schema changes, normal offline failures, and documented
  rate limiting are operational issues unless they violate another invariant
  above.

## Known Limitations and Compensating Controls

- Claude and Codex integrations depend on local CLI behavior that may change
  without notice.
- Executable discovery checks that a resolved path exists and is executable; it
  does not prove vendor identity or code signature. Users must select only CLI
  installations they trust.
- Real account payloads are not stored in automated tests. Synthetic fixtures,
  redacted diagnostics, and manual smoke tests are used instead.
- Releases are ad-hoc signed but are not notarized. Ad-hoc signing and a
  checksum establish local consistency, not publisher identity.
- Installation and Gatekeeper handling have not yet been validated on an
  independent clean Mac.
- The app has no automatic-update mechanism.
- `./scripts/verify.sh` builds the shipping target but runs AppKit diagnostics
  from a temporary, uniquely identified, ad-hoc-signed app copy. It compares an
  anonymous fingerprint of production app settings before and after, and removes
  the diagnostic preference domain and app copy on exit. Diagnostics must never
  run under the production bundle identifier.
- Provider transition generations, fail-closed numeric/time decoding, sparse
  Codex update merging, bounded ordered stdout ingress, bounded Claude and Codex
  subprocess termination, and provider-error sanitization have deterministic
  regression tests. Subprocess tests also read back the real cwd and `PWD`,
  require an empty local directory, reject `/`, and verify cleanup after exact
  child exit. Fixture cleanup uses a unique stop capability and never signals a
  PID read from a file. See
  [docs/VERIFICATION.md](docs/VERIFICATION.md).
- Packaging requires a clean committed version, signs and verifies the App,
  mounts the DMG read-only for content verification, and emits a SHA-256
  checksum. It does not mutate the project version or notarize/sign the DMG
  container itself.
