#!/bin/bash
# The project's verification entry point. Run this rather than hand-rolling commands.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/macos/AgentUsageBar"
PROJECT="$PACKAGE_DIR/App/AgentUsageBar/AgentUsageBar.xcodeproj"
cd "$ROOT"

DERIVED="${TMPDIR:-/tmp}/agent-usage-bar-verify-dd"
APP="$DERIVED/Build/Products/Debug/AgentUsageBar.app"
PRODUCTION_BIN="$APP/Contents/MacOS/AgentUsageBar"
RELEASE_APP="$DERIVED/Build/Products/Release/AgentUsageBar.app"
RELEASE_BIN="$RELEASE_APP/Contents/MacOS/AgentUsageBar"
PRODUCTION_BUNDLE_IDENTIFIER="io.github.sean.AgentUsageBar"

# The diagnostics intentionally exercise real AppKit objects, including NSStatusItem,
# and several app types correctly use UserDefaults.standard in production. Running
# those diagnostics from the shipping bundle would therefore give them the user's real
# preference domain. A separate bundle identifier is the complete boundary: it covers
# app settings, the persisted usage snapshot, and AppKit's own bundle-scoped state.
TEST_ROOT=""
TEST_BUNDLE_IDENTIFIER=""
PRODUCTION_SETTINGS_BEFORE=""
PREFERENCES_CHECKED=1
INSTANCE_TEST_PIDS=""
INSTANCE_LOCK_PATH=""

production_settings_fingerprint() {
  local key
  {
    for key in \
      v1.provider.claude.enabled \
      v1.provider.claude.identityColor \
      v1.provider.claude.refreshInterval \
      v1.provider.codex.enabled \
      v1.provider.codex.identityColor \
      v1.provider.codex.refreshInterval \
      v1.menuBarLayout \
      v1.displayLanguage \
      v1.claudeExecutablePath \
      v1.codexExecutablePath \
      v1.diagnosticRetentionDays \
      v1.diagnosticLog
    do
      printf '%s\0' "$key"
      if /usr/bin/defaults read "$PRODUCTION_BUNDLE_IDENTIFIER" "$key" 2>/dev/null; then
        :
      else
        printf '<missing>'
      fi
      printf '\0'
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

cleanup_diagnostic_bundle() {
  local status=$?
  local after
  local pid
  trap - EXIT

  # These are exact child PIDs retained from this verifier invocation, never values
  # reloaded from a file. Stop the isolated lock owner if a later assertion failed.
  for pid in $INSTANCE_TEST_PIDS; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
    wait "$pid" >/dev/null 2>&1 || true
  done

  # This runs on early failure too. It never restores a backup over live preferences:
  # a concurrent user change would make that destructive. Drift is reported instead.
  if [ "$PREFERENCES_CHECKED" -eq 0 ]; then
    after="$(production_settings_fingerprint)"
    if [ "$after" != "$PRODUCTION_SETTINGS_BEFORE" ]; then
      echo "FAIL: production app settings changed while isolated diagnostics ran" >&2
      status=1
    fi
  fi

  if [ -n "$TEST_BUNDLE_IDENTIFIER" ]; then
    /usr/bin/defaults delete "$TEST_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
  fi
  if [ -n "$TEST_ROOT" ] && [ -e "$TEST_ROOT" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$TEST_ROOT" >/dev/null 2>&1 \
        || echo "warning: retained diagnostic app at $TEST_ROOT" >&2
    else
      echo "warning: trash is unavailable; retained diagnostic app at $TEST_ROOT" >&2
    fi
  fi
  if [ -n "$INSTANCE_LOCK_PATH" ] && [ -e "$INSTANCE_LOCK_PATH" ]; then
    trash "$INSTANCE_LOCK_PATH" >/dev/null 2>&1 \
      || echo "warning: retained isolated instance lock at $INSTANCE_LOCK_PATH" >&2
  fi
  exit "$status"
}

echo "==> swift test (core logic)"
( cd "$PACKAGE_DIR" && swift test )

echo "==> xcodebuild Debug (diagnostic product)"
# Unsigned: this build is thrown away after the checks, and signing it would mean
# requiring a certificate to run the verification suite — which anyone contributing
# from another machine does not have.
# Package tests say nothing about whether the App target compiles the app layer.
# The Xcode target uses a synchronized folder, so a new file is a member automatically —
# but that is a claim worth re-proving on every run, not assuming.
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme AgentUsageBar \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build

echo "==> xcodebuild Release (the product that actually ships)"
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme AgentUsageBar \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build

echo "==> guard: Release excludes synthetic fixture surface"
test -x "$RELEASE_BIN" || { echo "FAIL: Release app binary missing" >&2; exit 1; }
if /usr/bin/grep -q 'UsageMeterFixtures' "$PROJECT/project.pbxproj"; then
  echo "FAIL: shipping Xcode target still depends on UsageMeterFixtures" >&2
  exit 1
fi
if /usr/bin/strings "$RELEASE_BIN" \
  | /usr/bin/grep -Eq 'UsageMeterFixtures|DemoScenario|FixtureUsageProvider|Fixtures are synthetic data'; then
  echo "FAIL: Release binary still contains synthetic fixture types or UI" >&2
  exit 1
fi
echo "ok: Release target and binary exclude synthetic fixture surface"

echo "==> bundle sanity"
test -f "$APP/Contents/Resources/AppIcon.icns" || { echo "FAIL: AppIcon.icns missing" >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = "true" \
  || { echo "FAIL: LSUIElement not set" >&2; exit 1; }
echo "ok: icon present and LSUIElement set"

echo "==> guard: preference-sensitive diagnostics reject the production bundle"
for diagnostic in --selftest --provider-transition-selftest; do
  if "$PRODUCTION_BIN" "$diagnostic" >/dev/null 2>&1; then
    echo "FAIL: the production bundle accepted $diagnostic" >&2
    exit 1
  else
    production_diagnostic_status=$?
  fi
  test "$production_diagnostic_status" -eq 2 \
    || { echo "FAIL: $diagnostic guard returned $production_diagnostic_status, expected 2" >&2; exit 1; }
done
echo "ok: production bundle refuses preference-sensitive diagnostics"

echo "==> isolated diagnostic bundle"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" \
  = "$PRODUCTION_BUNDLE_IDENTIFIER" \
  || { echo "FAIL: unexpected production bundle identifier" >&2; exit 1; }

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-bar-diagnostics.XXXXXX")"
TEST_BUNDLE_IDENTIFIER="$PRODUCTION_BUNDLE_IDENTIFIER.verification-$$"
TEST_APP="$TEST_ROOT/AgentUsageBar.app"
TEST_BIN="$TEST_APP/Contents/MacOS/AgentUsageBar"
INSTANCE_LOCK_PATH="${TMPDIR:-/tmp}/${TEST_BUNDLE_IDENTIFIER}.instance.lock"
PRODUCTION_SETTINGS_BEFORE="$(production_settings_fingerprint)"
PREFERENCES_CHECKED=0
trap cleanup_diagnostic_bundle EXIT

/usr/bin/defaults delete "$TEST_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
ditto "$APP" "$TEST_APP"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $TEST_BUNDLE_IDENTIFIER" \
  "$TEST_APP/Contents/Info.plist"
codesign --force --deep --sign - "$TEST_APP" >/dev/null
codesign --verify --deep --strict "$TEST_APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TEST_APP/Contents/Info.plist")" \
  = "$TEST_BUNDLE_IDENTIFIER" \
  || { echo "FAIL: diagnostic bundle identifier was not isolated" >&2; exit 1; }
echo "ok: diagnostics use $TEST_BUNDLE_IDENTIFIER, not the production preference domain"

echo "==> atomic single-instance ownership (simultaneous isolated launches)"
"$TEST_BIN" --instance-lock-hold >/dev/null 2>&1 &
first_instance_pid=$!
"$TEST_BIN" --instance-lock-hold >/dev/null 2>&1 &
second_instance_pid=$!
INSTANCE_TEST_PIDS="$first_instance_pid $second_instance_pid"
sleep 1

instance_is_running() {
  local state
  state="$(/bin/ps -o state= -p "$1" 2>/dev/null | /usr/bin/tr -d ' ')"
  case "$state" in
    ""|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

running_instances=0
instance_is_running "$first_instance_pid" && running_instances=$((running_instances + 1))
instance_is_running "$second_instance_pid" && running_instances=$((running_instances + 1))
test "$running_instances" -eq 1 \
  || { echo "FAIL: simultaneous launches left $running_instances lock owners" >&2; exit 1; }

for pid in $INSTANCE_TEST_PIDS; do
  wait "$pid" >/dev/null 2>&1 || true
done
INSTANCE_TEST_PIDS=""
echo "ok: exactly one process held the kernel lock; the duplicate exited"

echo "==> status bar self-test (real NSStatusItem wiring, isolated preferences)"
"$TEST_BIN" --selftest

echo "==> provider transition self-test (isolated preferences + synthetic providers)"
"$TEST_BIN" --provider-transition-selftest

echo "==> UI render check (isolated preferences)"
mkdir -p "$ROOT/dist"
"$TEST_BIN" --render-popover "$ROOT/dist/ui.png"

echo "==> gauge contact sheet (light + dark)"
"$TEST_BIN" --render-sheet "$ROOT/dist/gauges.png"

PRODUCTION_SETTINGS_AFTER="$(production_settings_fingerprint)"
PREFERENCES_CHECKED=1
if [ "$PRODUCTION_SETTINGS_AFTER" != "$PRODUCTION_SETTINGS_BEFORE" ]; then
  echo "FAIL: production app settings changed while isolated diagnostics ran" >&2
  exit 1
fi
echo "ok: production app settings are unchanged"

echo "==> guard: one committed release metadata source"
VERSION_CONFIG="$PACKAGE_DIR/App/AgentUsageBar/Config/Version.xcconfig"
SHARED_CONFIG="$PACKAGE_DIR/App/AgentUsageBar/Config/Shared.xcconfig"
test -f "$VERSION_CONFIG" \
  || { echo "FAIL: missing committed Version.xcconfig" >&2; exit 1; }
/bin/zsh -c '
  source "$1/scripts/release_common.zsh"
  aub_read_release_metadata "$2"
  print -- "$AUB_MARKETING_VERSION|$AUB_BUILD_NUMBER|$AUB_RELEASE_SUFFIX"
' -- "$ROOT" "$VERSION_CONFIG" >/dev/null \
  || { echo "FAIL: committed release metadata is invalid" >&2; exit 1; }
grep -Fq '#include "Version.xcconfig"' "$SHARED_CONFIG" \
  || { echo "FAIL: Shared.xcconfig does not include Version.xcconfig" >&2; exit 1; }
if grep -Eq '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ' "$PROJECT/project.pbxproj"; then
  echo "FAIL: Xcode project duplicates committed release metadata" >&2
  exit 1
fi
grep -q '<key>AUBReleaseSuffix</key>' \
  "$PACKAGE_DIR/App/AgentUsageBar/AgentUsageBar/Info.plist" \
  || { echo "FAIL: packaged suffix is not available for readback" >&2; exit 1; }
test -x scripts/release.sh \
  || { echo "FAIL: missing executable scripts/release.sh" >&2; exit 1; }
echo "ok: version, build, and suffix have one committed source"

echo "==> packaging preflight (clean committed source only)"
(
  PACKAGING_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-bar-packaging-fixture.XXXXXX")"
  cleanup_packaging_fixture() {
    if [ -e "$PACKAGING_FIXTURE_ROOT" ]; then
      trash "$PACKAGING_FIXTURE_ROOT" >/dev/null 2>&1 \
        || echo "warning: retained packaging fixture at $PACKAGING_FIXTURE_ROOT" >&2
    fi
  }
  trap cleanup_packaging_fixture EXIT

  mkdir -p \
    "$PACKAGING_FIXTURE_ROOT/scripts" \
    "$PACKAGING_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config"
  cp "$ROOT/scripts/package_dmg.sh" "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh"
  cp "$ROOT/scripts/release_common.zsh" "$PACKAGING_FIXTURE_ROOT/scripts/release_common.zsh"
  cp "$VERSION_CONFIG" \
    "$PACKAGING_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig"
  chmod +x "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh"

  git -C "$PACKAGING_FIXTURE_ROOT" init -q -b main
  git -C "$PACKAGING_FIXTURE_ROOT" config user.name 'Agent Usage Bar Test'
  git -C "$PACKAGING_FIXTURE_ROOT" config user.email 'fixture@example.invalid'
  git -C "$PACKAGING_FIXTURE_ROOT" config commit.gpgSign false
  git -C "$PACKAGING_FIXTURE_ROOT" add .
  git -C "$PACKAGING_FIXTURE_ROOT" commit -qm 'fixture: clean release source'

  preflight_output="$($PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh --preflight)"
  echo "$preflight_output" | grep -q 'Packaging preflight passed.' \
    || { echo "FAIL: clean packaging preflight did not pass" >&2; exit 1; }
  preflight_version_line="$(echo "$preflight_output" | grep '^Version: ')"
  test -n "$preflight_version_line" \
    || { echo "FAIL: packaging did not report the committed version/build" >&2; exit 1; }
  test -z "$(git -C "$PACKAGING_FIXTURE_ROOT" status --porcelain)" \
    || { echo "FAIL: packaging preflight modified its source tree" >&2; exit 1; }

  git -C "$PACKAGING_FIXTURE_ROOT" commit --allow-empty -qm 'fixture: unrelated history change'
  history_output="$($PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh --preflight)"
  test "$(echo "$history_output" | grep '^Version: ')" = "$preflight_version_line" \
    || { echo "FAIL: build number still depends on Git commit count" >&2; exit 1; }

  if VERSION_OVERRIDE=9.9.9 \
    "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh" --preflight >/dev/null 2>&1; then
    echo "FAIL: packaging accepted an uncommitted version override" >&2
    exit 1
  fi

  if RELEASE_SUFFIX_OVERRIDE=beta.1 \
    "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh" --preflight >/dev/null 2>&1; then
    echo "FAIL: packaging accepted an uncommitted suffix override" >&2
    exit 1
  fi

  if "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh" >/dev/null 2>&1; then
    echo "FAIL: packaging wrote a release without an exact release plan" >&2
    exit 1
  fi

  if SIGN_IDENTITY_OVERRIDE='Apple Development: fixture@example.invalid (XXXXXXXXXX)' \
    "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh" --preflight >/dev/null 2>&1; then
    echo "FAIL: packaging accepted an Apple Development identity for a public artifact" >&2
    exit 1
  fi

  explicit_signer_output="$(SIGN_IDENTITY_OVERRIDE='Developer ID Application: Fixture (XXXXXXXXXX)' \
    "$PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh" --preflight)"
  echo "$explicit_signer_output" | grep -q 'explicit Developer ID Application identity' \
    || { echo "FAIL: packaging did not acknowledge the explicit public signer" >&2; exit 1; }

  touch "$PACKAGING_FIXTURE_ROOT/uncommitted.txt"
  if dirty_output="$($PACKAGING_FIXTURE_ROOT/scripts/package_dmg.sh --preflight 2>&1)"; then
    echo "FAIL: packaging accepted a dirty working tree" >&2
    exit 1
  fi
  echo "$dirty_output" | grep -q 'requires a clean working tree' \
    || { echo "FAIL: dirty packaging rejection was not explicit" >&2; exit 1; }
)

echo "==> release transaction fixture"
(
  RELEASE_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-bar-release-fixture.XXXXXX")"
  cleanup_release_fixture() {
    if [ -e "$RELEASE_FIXTURE_ROOT" ]; then
      trash "$RELEASE_FIXTURE_ROOT" >/dev/null 2>&1 \
        || echo "warning: retained release fixture at $RELEASE_FIXTURE_ROOT" >&2
    fi
  }
  trap cleanup_release_fixture EXIT

  mkdir -p \
    "$RELEASE_FIXTURE_ROOT/scripts" \
    "$RELEASE_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config"
  cp "$ROOT/scripts/release.sh" "$RELEASE_FIXTURE_ROOT/scripts/release.sh"
  cp "$ROOT/scripts/release_common.zsh" "$RELEASE_FIXTURE_ROOT/scripts/release_common.zsh"
  printf '%s\n' \
    '// Fixed fixture for the first public candidate policy.' \
    'MARKETING_VERSION = 0.3.2' \
    'CURRENT_PROJECT_VERSION = 1' \
    'AUB_RELEASE_SUFFIX = alpha.1' \
    > "$RELEASE_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig"
  printf '%s\n' '/tmp/' '/dist/' > "$RELEASE_FIXTURE_ROOT/.gitignore"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$RELEASE_FIXTURE_ROOT/scripts/verify.sh"
  printf '%s\n' '#!/bin/sh' \
    'case "$1" in --release-plan|--verify-candidate) test -f "$2" ;; *) exit 1 ;; esac' \
    > "$RELEASE_FIXTURE_ROOT/scripts/package_dmg.sh"
  chmod +x \
    "$RELEASE_FIXTURE_ROOT/scripts/release.sh" \
    "$RELEASE_FIXTURE_ROOT/scripts/verify.sh" \
    "$RELEASE_FIXTURE_ROOT/scripts/package_dmg.sh"

  git -C "$RELEASE_FIXTURE_ROOT" init -q -b main
  git -C "$RELEASE_FIXTURE_ROOT" config user.name 'Agent Usage Bar Test'
  git -C "$RELEASE_FIXTURE_ROOT" config user.email 'fixture@example.invalid'
  git -C "$RELEASE_FIXTURE_ROOT" config commit.gpgSign false
  git -C "$RELEASE_FIXTURE_ROOT" add .
  git -C "$RELEASE_FIXTURE_ROOT" commit -qm 'fixture: release tooling'

  before_head="$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD)"
  before_tree="$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD^{tree})"
  before_refs="$(git -C "$RELEASE_FIXTURE_ROOT" for-each-ref --format='%(refname) %(objectname)')"
  plan_output="$($RELEASE_FIXTURE_ROOT/scripts/release.sh plan --next-minor)"
  echo "$plan_output" | grep -q 'Target: 0.4.100 (4100)' \
    || { echo "FAIL: first public release plan is incorrect" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD)" = "$before_head" \
    || { echo "FAIL: release plan changed HEAD" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD^{tree})" = "$before_tree" \
    || { echo "FAIL: release plan changed the tree" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" \
    || { echo "FAIL: release plan changed refs" >&2; exit 1; }
  test -z "$(git -C "$RELEASE_FIXTURE_ROOT" status --porcelain)" \
    || { echo "FAIL: release plan changed the working tree" >&2; exit 1; }

  if "$RELEASE_FIXTURE_ROOT/scripts/release.sh" plan >/dev/null 2>&1; then
    echo "FAIL: first public candidate did not require --next-minor" >&2
    exit 1
  fi

  "$RELEASE_FIXTURE_ROOT/scripts/release.sh" prepare --next-minor >/dev/null
  grep -q '^MARKETING_VERSION = 0\.4\.100$' \
    "$RELEASE_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig" \
    || { echo "FAIL: prepare did not commit the target marketing version" >&2; exit 1; }
  grep -q '^CURRENT_PROJECT_VERSION = 4100$' \
    "$RELEASE_FIXTURE_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig" \
    || { echo "FAIL: prepare did not commit the target build" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" log -1 --format=%s)" = \
    'release: prepare v0.4.100-alpha.1' \
    || { echo "FAIL: prepare commit subject is incorrect" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" diff-tree --no-commit-id --name-only -r HEAD)" = \
    'macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig' \
    || { echo "FAIL: prepare commit contains an unexpected path" >&2; exit 1; }
  test -z "$(git -C "$RELEASE_FIXTURE_ROOT" status --porcelain)" \
    || { echo "FAIL: prepare left Git-visible changes" >&2; exit 1; }
  test -n "$(find "$RELEASE_FIXTURE_ROOT/tmp/release-transactions" -name '*.json' -print -quit)" \
    || { echo "FAIL: prepare did not retain a transaction record" >&2; exit 1; }

  source_commit="$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD)"
  source_tree="$(git -C "$RELEASE_FIXTURE_ROOT" rev-parse HEAD^{tree})"
  mkdir -p "$RELEASE_FIXTURE_ROOT/dist"
  manifest="$RELEASE_FIXTURE_ROOT/dist/Agent-Usage-Bar-0.4.100-alpha.1-b4100-arm64.dmg.candidate.json"
  manifest_builder="$RELEASE_FIXTURE_ROOT/tmp/finalize-fixture.plist"
  /usr/bin/plutil -create xml1 "$manifest_builder"
  /usr/bin/plutil -insert sourceCommit -string "$source_commit" "$manifest_builder"
  /usr/bin/plutil -insert sourceTree -string "$source_tree" "$manifest_builder"
  /usr/bin/plutil -insert expectedTag -string 'v0.4.100-alpha.1' "$manifest_builder"
  /usr/bin/plutil -insert releaseVersion -string '0.4.100-alpha.1' "$manifest_builder"
  /usr/bin/plutil -insert buildNumber -integer 4100 "$manifest_builder"
  /usr/bin/plutil -insert dmgBasename -string \
    'Agent-Usage-Bar-0.4.100-alpha.1-b4100-arm64.dmg' "$manifest_builder"
  /usr/bin/plutil -insert dmgBytes -integer 1234 "$manifest_builder"
  /usr/bin/plutil -insert dmgSHA256 -string \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$manifest_builder"
  /usr/bin/plutil -insert checksumBasename -string \
    'Agent-Usage-Bar-0.4.100-alpha.1-b4100-arm64.dmg.sha256' "$manifest_builder"
  /usr/bin/plutil -insert architecture -string arm64 "$manifest_builder"
  /usr/bin/plutil -convert json -o "$manifest" "$manifest_builder"

  transaction="$RELEASE_FIXTURE_ROOT/tmp/release-transactions/$source_commit.json"
  transaction_builder="$RELEASE_FIXTURE_ROOT/tmp/finalize-transaction.plist"
  /usr/bin/plutil -convert xml1 -o "$transaction_builder" "$transaction"
  /usr/bin/plutil -replace state -string packaged "$transaction_builder"
  /usr/bin/plutil -insert dmgBytes -integer 1234 "$transaction_builder"
  /usr/bin/plutil -insert dmgSHA256 -string \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$transaction_builder"
  /usr/bin/plutil -insert manifestSHA256 -string \
    "$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')" "$transaction_builder"
  /usr/bin/plutil -convert json -o "$transaction" "$transaction_builder"

  finalize_output="$($RELEASE_FIXTURE_ROOT/scripts/release.sh finalize "$manifest")"
  test "$(git -C "$RELEASE_FIXTURE_ROOT" cat-file -t refs/tags/v0.4.100-alpha.1)" = tag \
    || { echo "FAIL: finalize did not create an annotated tag" >&2; exit 1; }
  test "$(git -C "$RELEASE_FIXTURE_ROOT" rev-list -n 1 v0.4.100-alpha.1)" = "$source_commit" \
    || { echo "FAIL: finalize tag does not point to the candidate commit" >&2; exit 1; }
  echo "$finalize_output" | grep -Fq 'git push origin main' \
    || { echo "FAIL: finalize did not print the branch push command" >&2; exit 1; }
  echo "$finalize_output" | grep -Fq 'git push origin v0.4.100-alpha.1' \
    || { echo "FAIL: finalize did not print the exact tag push command" >&2; exit 1; }
  repeated_finalize_output="$($RELEASE_FIXTURE_ROOT/scripts/release.sh finalize "$manifest")" \
    || { echo "FAIL: exact repeated finalize was not idempotent" >&2; exit 1; }
  echo "$repeated_finalize_output" | grep -Fq 'git push origin v0.4.100-alpha.1' \
    || { echo "FAIL: repeated finalize did not print the exact tag push command" >&2; exit 1; }

  mv "$transaction" "$transaction.saved"
  "$RELEASE_FIXTURE_ROOT/scripts/release.sh" finalize "$manifest" >/dev/null \
    || { echo "FAIL: finalized tag readback still depends on ignored tmp state" >&2; exit 1; }

  /usr/bin/plutil -replace dmgBytes -integer 1235 "$manifest"
  if "$RELEASE_FIXTURE_ROOT/scripts/release.sh" finalize "$manifest" >/dev/null 2>&1; then
    echo "FAIL: finalize accepted a candidate that no longer matches its packaged transaction" >&2
    exit 1
  fi
)

/bin/zsh -c '
  source "$1/scripts/release_common.zsh"
  fixture=$2
  print "MARKETING_VERSION = 0.4.999\nCURRENT_PROJECT_VERSION = 4999\nAUB_RELEASE_SUFFIX = alpha.1" > "$fixture"
  aub_read_release_metadata "$fixture"
  aub_compute_next_release 1 0
  [[ "$AUB_TARGET_MARKETING_VERSION" == "0.5.100" && "$AUB_TARGET_BUILD_NUMBER" == "5000" ]]
  if aub_compute_next_release 0 0 >/dev/null 2>&1; then exit 1; fi
' -- "$ROOT" "${TMPDIR:-/tmp}/agent-usage-bar-version-policy.$$"
trash "${TMPDIR:-/tmp}/agent-usage-bar-version-policy.$$" >/dev/null 2>&1 || true

if grep -q '/usr/bin/sed -i' scripts/package_dmg.sh; then
  echo "FAIL: packaging still writes MARKETING_VERSION" >&2
  exit 1
fi
grep -Fq 'rev-parse HEAD^{tree}' scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not recheck the exact source tree" >&2; exit 1; }
grep -q "Print :AUBSourceCommit" scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not verify embedded source commit" >&2; exit 1; }
grep -Fq '"$GIT" -C "$REPOSITORY_ROOT" archive' scripts/package_dmg.sh \
  || grep -Fq '$GIT -C "$REPOSITORY_ROOT" archive' scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not build from a tracked source export" >&2; exit 1; }
grep -Fq 'ARCHS="$ARCHITECTURE"' scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not constrain the binary to the planned architecture" >&2; exit 1; }
grep -Fq 'ONLY_ACTIVE_ARCH=YES' scripts/package_dmg.sh \
  || { echo "FAIL: packaging can still emit architectures outside the release plan" >&2; exit 1; }
if grep -q 'security find-identity' scripts/package_dmg.sh; then
  echo "FAIL: packaging still auto-selects a machine signing identity" >&2
  exit 1
fi
if grep -q 'LocalSigning.xcconfig' \
  macos/AgentUsageBar/App/AgentUsageBar/Config/Shared.xcconfig; then
  echo "FAIL: shared Xcode settings still include machine-local signing configuration" >&2
  exit 1
fi
local_signing_path="$(find macos/AgentUsageBar/App/AgentUsageBar/Config \
  -maxdepth 1 -name 'LocalSigning.xcconfig*' -print -quit)"
if [ -n "$local_signing_path" ]; then
  echo "FAIL: repository still contains a machine-local signing configuration path: $local_signing_path" >&2
  exit 1
fi
echo "ok: packaging builds an isolated tracked commit with explicit signing policy"

echo "==> guard: GitHub Actions uses the same read-only verifier"
WORKFLOW=".github/workflows/verify.yml"
test -f "$WORKFLOW" || { echo "FAIL: missing $WORKFLOW" >&2; exit 1; }
grep -q 'runs-on: macos-26' "$WORKFLOW" \
  || { echo "FAIL: CI runner is not pinned to macos-26" >&2; exit 1; }
grep -q 'DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer' "$WORKFLOW" \
  || { echo "FAIL: CI Xcode toolchain is not pinned" >&2; exit 1; }
grep -q 'uses: actions/checkout@v6' "$WORKFLOW" \
  || { echo "FAIL: CI checkout action is not the reviewed major version" >&2; exit 1; }
grep -q 'persist-credentials: false' "$WORKFLOW" \
  || { echo "FAIL: CI checkout retains push credentials" >&2; exit 1; }

# Private coordination and retired credential experiments are local development records,
# not public source. This also makes an accidental re-add fail before a repository reset.
if [[ -n "$(git ls-files -ci --exclude-standard)" ]]; then
  echo "FAIL: ignored local-only files are still tracked:" >&2
  git ls-files -ci --exclude-standard >&2
  exit 1
fi

if [[ -e scripts/spike-d1.sh ]]; then
  echo "FAIL: retired credential-bearing spike is present" >&2
  exit 1
fi
grep -q 'contents: read' "$WORKFLOW" \
  || { echo "FAIL: CI token does not declare read-only contents access" >&2; exit 1; }
grep -q 'run: ./scripts/verify.sh' "$WORKFLOW" \
  || { echo "FAIL: CI duplicates or bypasses the authoritative verifier" >&2; exit 1; }
if grep -Eq 'pull_request_target|(^|[[:space:]])(write-all|[a-z-]+:[[:space:]]*write)([[:space:]]|$)|secrets\.' "$WORKFLOW"; then
  echo "FAIL: CI workflow requests a write/security-sensitive surface" >&2
  exit 1
fi
echo "ok: CI is read-only and delegates to ./scripts/verify.sh"

echo "==> guard: release packaging freezes trusted tool paths"
grep -q 'typeset -r GIT=/usr/bin/git' scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not freeze the Git trust anchor" >&2; exit 1; }
grep -q 'typeset -r XCODEBUILD=/usr/bin/xcodebuild' scripts/package_dmg.sh \
  || { echo "FAIL: packaging does not freeze the Xcode trust anchor" >&2; exit 1; }
bare_release_tools="$(grep -nE \
  '^[[:space:]]*(git|xcodebuild|codesign|hdiutil|shasum)([[:space:]]|$)|\$\((git|xcodebuild|codesign|hdiutil|shasum)([[:space:]]|$)' \
  scripts/package_dmg.sh || true)"
if [ -n "$bare_release_tools" ]; then
  echo "FAIL: release-critical packaging tools are still invoked through PATH" >&2
  echo "$bare_release_tools" >&2
  exit 1
fi
if grep -q '以開發憑證簽章' README.md; then
  echo "FAIL: README still describes the ad-hoc release as development-certificate signed" >&2
  exit 1
fi
echo "ok: release tooling and signing documentation use explicit trust anchors"

echo "==> guard: the retired keychain + endpoint path stays retired"
# 0.3.0 replaced the OAuth-credential path with `claude -p /usage`. Bringing any part of
# the old one back would restore the whole risk surface it was removed for: a token this
# app has no business holding, a repeating keychain dialog, and a wire identity
# indistinguishable from the official CLI. docs/LEGACY_KEYCHAIN_PATH.md records what the
# path did and the conditions under which returning to it would be a decision rather
# than an accident — and that decision belongs in a design discussion, not a diff.
# Comment lines are excluded: the docs deliberately name what was removed, and a guard
# that forbids describing the retirement would push that reasoning out of the codebase.
retired="$(grep -rn --include='*.swift' -E \
  'api/oauth/usage|Claude Code-credentials|SecItemCopyMatching|/usr/bin/security|claude-cli/|ClientIdentity|KeychainCredentialReader|ClaudeCredentialCache|CredentialRefreshTrigger|case credentialChanged' \
  macos/AgentUsageBar/Sources \
  | grep -vE ':[[:space:]]*(//|\*)' || true)"
if [ -n "$retired" ]; then
  echo "FAIL: the retired Claude credential/endpoint path has returned:" >&2
  echo "$retired" >&2
  exit 1
fi
echo "ok: no keychain read, no usage endpoint, no CLI impersonation"

echo "==> guard: the core never assumes main-actor isolation"
# UsageMeterCore is pure logic called from async provider code that is not main-actor
# isolated. `MainActor.assumeIsolated` asserts the caller is already on the main actor
# rather than moving it there, so one of these in the core is a runtime trap waiting for
# the first real query — which is exactly how a crash reached a shipped build. The live
# smoke test cannot catch it, because reaching the success path needs a real keychain
# item and therefore a real password prompt.
core_isolation="$(grep -rn --include='*.swift' 'MainActor.assumeIsolated' \
  macos/AgentUsageBar/Sources/UsageMeterCore \
  | grep -vE ':[[:space:]]*//' || true)"
if [ -n "$core_isolation" ]; then
  echo "FAIL: UsageMeterCore 不得使用 MainActor.assumeIsolated：" >&2
  echo "$core_isolation" >&2
  exit 1
fi
echo "ok: core has no main-actor assumptions"

echo "==> guard: retired PollPolicy surface stays removed"
# RefreshInterval owns the user's periodic schedule and FetchPacing owns the request
# floor. PollPolicy was never read by either path; keeping a second set of intervals
# made provider declarations look operational when they were not.
dead_poll_policy="$(grep -rn --include='*.swift' -E 'PollPolicy|pollPolicy' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$dead_poll_policy" ]; then
  echo "FAIL: unused PollPolicy surface has returned:" >&2
  echo "$dead_poll_policy" >&2
  exit 1
fi
echo "ok: scheduling has no unused PollPolicy surface"

echo "==> guard: retired HTTP backoff fields stay removed"
# Live providers are CLI and JSON-RPC readers; neither emits an HTTP Retry-After or
# the retired endpoint's assumed penalty window. Generic exponential retry remains.
retired_http_backoff="$(grep -rn --include='*.swift' -E \
  'retryAfterPadding|retryAfterCap|assumedPenaltyWindow|capExceedsPenaltyWindow' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$retired_http_backoff" ]; then
  echo "FAIL: retired HTTP backoff fields have returned:" >&2
  echo "$retired_http_backoff" >&2
  exit 1
fi
echo "ok: retry backoff has no retired HTTP-only fields"

echo "==> guard: UsageProvider stays fetch-only"
# Presenter owns identity and retry state; snapshots carry the identity that reaches
# persistence and UI. Requiring live provider objects to duplicate either is a fake API.
dead_provider_contract="$(grep -n -E 'provider: ProviderKind|backoffPolicy' \
  macos/AgentUsageBar/Sources/UsageMeterCore/Provider/UsageProvider.swift \
  macos/AgentUsageBar/Sources/UsageMeterCore/Claude/ClaudeUsageProvider.swift \
  macos/AgentUsageBar/Sources/UsageMeterCore/Codex/CodexUsageProvider.swift || true)"
if [ -n "$dead_provider_contract" ]; then
  echo "FAIL: UsageProvider or a live provider duplicates presenter-owned metadata:" >&2
  echo "$dead_provider_contract" >&2
  exit 1
fi
echo "ok: UsageProvider exposes only the fetch operation"

echo "==> guard: unconsumed diagnostic metadata stays removed"
# Schema keys remain available locally while decoding an error, but storing their
# names (or retired HTTP headers) in every persisted snapshot had no consumer.
dead_diagnostic_metadata="$(grep -rn --include='*.swift' -E \
  'localizedAccessOutcome|observedTopLevelKeys|rateLimitHeaders' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$dead_diagnostic_metadata" ]; then
  echo "FAIL: zero-consumer helper or snapshot diagnostics have returned:" >&2
  echo "$dead_diagnostic_metadata" >&2
  exit 1
fi
echo "ok: snapshots contain no unconsumed schema/header diagnostics"

echo "==> guard: unused upstream severity stays removed"
# Gauge colour is derived from the normalized percentage. Codex's user-visible raw
# limit status remains separately available as rateLimitReachedType.
dead_severity="$(grep -rn --include='*.swift' -E 'UsageSeverity|severity:' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$dead_severity" ]; then
  echo "FAIL: UsageWindow still carries upstream severity with no consumer:" >&2
  echo "$dead_severity" >&2
  exit 1
fi
echo "ok: UsageWindow has no unconsumed upstream severity"

echo "==> guard: unsupported Extra Usage surface stays removed"
# Neither live provider has a stable read-only source for this account setting. Keeping
# a model or UI field would falsely advertise support and invite a billing-mutating probe.
dead_extra_usage="$(grep -rn --include='*.swift' -E 'extraUsageEnabled|Extra usage: disabled' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$dead_extra_usage" ]; then
  echo "FAIL: unsupported Extra Usage model or UI surface has returned:" >&2
  echo "$dead_extra_usage" >&2
  exit 1
fi
echo "ok: shipping sources contain no unsupported Extra Usage surface"

echo "==> guard: Codex provider stays read-only"
codex_writes="$(grep -rn --include='*.swift' -E 'account/(login|logout|rateLimitResetCredit/consume|sendAddCreditsNudgeEmail)' \
  macos/AgentUsageBar/Sources || true)"
if [ -n "$codex_writes" ]; then
  echo "FAIL: Codex shipping sources contain an account mutation method:" >&2
  echo "$codex_writes" >&2
  exit 1
fi
echo "ok: Codex sources contain no account mutation method"

echo "==> guard: the Claude provider runs one fixed read-only command"
# The app now executes a CLI, so the blast radius is decided entirely by whether the
# argument list can vary. Exactly one file may construct a Process, and the argument
# list is asserted literally here as well as in the unit tests: a static check cannot be
# routed around by a refactor that keeps the tests passing.
claude_processes="$(grep -rn --include='*.swift' -E 'Process\(\)' \
  macos/AgentUsageBar/Sources/UsageMeterCore/Claude \
  | grep -v 'ClaudeUsageCommand.swift' || true)"
if [ -n "$claude_processes" ]; then
  echo "FAIL: only ClaudeUsageCommand.swift may start a subprocess:" >&2
  echo "$claude_processes" >&2
  exit 1
fi

# Renewal-by-side-effect once damaged the user's login state. `/usage` is documented
# and read-only; these are not, and none of them may appear in an argument
# list, however plausible the reason.
forbidden_subcommands="$(grep -rn --include='*.swift' -E \
  '"(doctor|mcp|auth|login|logout|setup-token|update|/?usage-credits|/?extra-usage|--continue|--resume|--dangerously-skip-permissions)"' \
  macos/AgentUsageBar/Sources/UsageMeterCore/Claude || true)"
if [ -n "$forbidden_subcommands" ]; then
  echo "FAIL: a non-read-only Claude subcommand appears in the provider:" >&2
  echo "$forbidden_subcommands" >&2
  exit 1
fi

# No shell: a shell would reintroduce quoting and injection as a concern where there is
# currently none.
claude_shell="$(grep -rn --include='*.swift' -E '/bin/(ba)?sh|/bin/zsh|"-c"' \
  macos/AgentUsageBar/Sources/UsageMeterCore/Claude || true)"
if [ -n "$claude_shell" ]; then
  echo "FAIL: the Claude provider must execute the binary directly, never via a shell:" >&2
  echo "$claude_shell" >&2
  exit 1
fi

# Compared after collapsing whitespace so the source can stay readable across lines,
# while still pinning the exact tokens and their order.
expected_arguments='"--safe-mode","--no-session-persistence","-p","/usage","--output-format","json",'
actual_arguments="$(sed -n '/public static let arguments = \[/,/^    \]/p' \
  macos/AgentUsageBar/Sources/UsageMeterCore/Claude/ClaudeUsageCommand.swift \
  | tr -d ' \t\n' \
  | sed 's/^publicstaticletarguments=\[//; s/\]$//')"
if [ "$actual_arguments" != "$expected_arguments" ]; then
  echo "FAIL: the approved /usage argument list has changed:" >&2
  echo "  expected: $expected_arguments" >&2
  echo "  actual:   $actual_arguments" >&2
  exit 1
fi
echo "ok: one fixed, read-only, shell-free Claude command"

echo "==> guard: process fixtures never signal a PID read from a file"
# Shipping lifecycle code retains the exact Process instance it launched. Test cleanup
# must not weaken that rule by saving a bare PID and signalling whatever owns the same
# number later; PID values can be reused after the fixture exits.
unsafe_fixture_cleanup="$(grep -nE 'kill\(|SIGKILL|write_pids|\.pids' \
  macos/AgentUsageBar/Tests/UsageMeterCoreTests/ClaudeProcessRunnerTests.swift \
  macos/AgentUsageBar/Tests/Fixtures/claude-process-runner-stub || true)"
if [ -n "$unsafe_fixture_cleanup" ]; then
  echo "FAIL: a process fixture can signal a bare persisted PID:" >&2
  echo "$unsafe_fixture_cleanup" >&2
  exit 1
fi
echo "ok: process fixture cleanup uses only its unique stop capability"

echo "==> guard: duplicate app launches never terminate peer applications"
if grep -q '\.terminate()' macos/AgentUsageBar/Sources/AgentUsageBar/main.swift \
  macos/AgentUsageBar/Sources/AgentUsageBar/AppInstanceCoordinator.swift; then
  echo "FAIL: duplicate-instance startup may terminate an unrelated peer app" >&2
  exit 1
fi
grep -q 'AppInstanceCoordinator.shouldContinueLaunching()' \
  macos/AgentUsageBar/Sources/AgentUsageBar/main.swift \
  || { echo "FAIL: shipping startup no longer enforces the single-instance boundary" >&2; exit 1; }
grep -Fq 'flock(descriptor, LOCK_EX | LOCK_NB)' \
  macos/AgentUsageBar/Sources/AgentUsageBar/AppInstanceCoordinator.swift \
  || { echo "FAIL: single-instance ownership is no longer an atomic kernel lock" >&2; exit 1; }
if grep -qE 'processIdentifier[[:space:]]*</|min\(by:.*processIdentifier' \
  macos/AgentUsageBar/Sources/AgentUsageBar/AppInstanceCoordinator.swift; then
  echo "FAIL: single-instance ownership must not infer process age from PID ordering" >&2
  exit 1
fi
echo "ok: an atomic owner survives while a newer duplicate only asks it to surface Settings"

echo "==> guard: no rm in scripts (deletions must be recoverable)"
if grep -nE '(^|[^a-zA-Z_])rm[[:space:]]+-' scripts/*.sh; then
  echo "FAIL: use trash instead of rm" >&2
  exit 1
fi
echo "ok: scripts use trash"

echo "==> git diff --check"
git diff --check

echo
echo "All checks passed."
