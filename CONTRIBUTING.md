# Contributing to Agent Usage Bar

Thanks for helping improve Agent Usage Bar. This is a small prerelease macOS
project, so focused changes that preserve its privacy and read-only boundaries
are easiest to review.

## Before Opening an Issue

- Search existing issues before filing a duplicate.
- Use a regular issue for bugs, feature requests, and documentation problems.
- Follow [SECURITY.md](SECURITY.md) for vulnerabilities. Never post credentials,
  tokens, private account data, or exploitable details in a public issue.

## Development Requirements

- macOS 14 or later
- Apple Silicon
- Xcode with the macOS SDK
- Swift Package Manager

The automated tests do not require a Claude or Codex account. Do not add live
account access to the default test or CI path.

Open the Xcode project when working on the app:

```bash
open macos/AgentUsageBar/App/AgentUsageBar/AgentUsageBar.xcodeproj
```

The intended authoritative verification command is:

```bash
./scripts/verify.sh
```

It runs the Swift tests, builds the actual Xcode app target without signing,
checks the bundle and status-bar wiring, renders the UI, and runs the static
safety guards. A standalone `swift test` run is not sufficient for app changes.
GitHub Actions delegates to this same script on `macos-26` with Xcode 26.6 and
read-only repository permissions; do not create a second CI-only test path.

AppKit diagnostics do not run from the shipping bundle. The script copies the
unsigned product to a temporary app, gives it a unique bundle identifier,
ad-hoc signs it, and runs the status-bar and render checks there. It verifies
that production app settings are unchanged, then removes the diagnostic
preference domain. It moves the app copy to Trash when available; otherwise it
reports the retained path. See [docs/VERIFICATION.md](docs/VERIFICATION.md) for
the isolation contract and current regression coverage.

## Signing and Packaging

The shared Xcode project intentionally contains no personal Apple Team,
certificate, or machine-local signing include. Do not commit signing identities,
provisioning profiles, certificates, private keys, or local build overrides.

The default ad-hoc policy and future explicit Developer ID path are documented in
[docs/SIGNING.md](docs/SIGNING.md). DMG packaging is documented in
[docs/PACKAGING.md](docs/PACKAGING.md). Packaging changes must preserve isolated
tracked-source, version, signature, mounted-content, and checksum verification.

## Change Guidelines

- Keep Claude and Codex provider operations account-read-only.
- Never log, display, persist, or commit credentials or raw provider responses.
- Use synthetic, neutral fixture values. Do not copy a real payload into the
  repository, even after partial redaction.
- Start subprocesses directly without a shell, and manage only processes the app
  created itself.
- Preserve bounded polling, backoff, and retry behavior.
- Treat malformed or unavailable data as unknown; never convert it to zero usage.
- Keep Traditional Chinese and English user-facing text in sync, including
  accessibility labels.
- Add or update focused tests when behavior or a security invariant changes.
- Update the relevant architecture, safety, UI, verification, or packaging
  documentation when its contract changes.

The detailed boundaries are documented in [docs/SAFETY.md](docs/SAFETY.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Pull Requests

Keep each pull request focused and explain:

- the user-visible outcome;
- the security or data-boundary impact;
- the tests and build checks run;
- any manual verification still required.

Before submitting, confirm:

- `./scripts/verify.sh` passes directly;
- `git diff --check` passes;
- no credential, personal signing value, build cache, DMG, or local configuration
  file is included;
- UI changes work in both supported languages and light/dark appearance when
  applicable.

## License

Unless explicitly stated otherwise, contributions intentionally submitted for
inclusion in this project are provided under the Apache License 2.0, as described
in [LICENSE](LICENSE).
