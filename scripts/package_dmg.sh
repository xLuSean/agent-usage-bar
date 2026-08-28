#!/bin/zsh

# Low-level deterministic DMG builder and candidate verifier. A writable release build
# requires the exact one-shot transaction plan created by scripts/release.sh prepare.

set -euo pipefail

typeset -r GIT=/usr/bin/git
typeset -r XCODEBUILD=/usr/bin/xcodebuild
typeset -r CODESIGN=/usr/bin/codesign
typeset -r HDIUTIL=/usr/bin/hdiutil
typeset -r DITTO=/usr/bin/ditto
typeset -r SHASUM=/usr/bin/shasum
typeset -r PLUTIL=/usr/bin/plutil
typeset -r TAR=/usr/bin/tar
typeset -r GREP=/usr/bin/grep
typeset -r AWK=/usr/bin/awk
typeset -r UNAME=/usr/bin/uname
typeset -r MKTEMP=/usr/bin/mktemp
typeset -r LIPO=/usr/bin/lipo
typeset -r MKDIR=/bin/mkdir
typeset -r LN=/bin/ln
typeset -r READLINK=/usr/bin/readlink
typeset -r STAT=/usr/bin/stat
typeset -r MV=/bin/mv
typeset -r TRASH=/usr/bin/trash

unset DEVELOPER_DIR TOOLCHAINS SDKROOT

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
source "$SCRIPT_DIR/release_common.zsh"

typeset -r PROJECT_RELATIVE_PATH="macos/AgentUsageBar/App/AgentUsageBar/AgentUsageBar.xcodeproj"
typeset -r SCHEME="AgentUsageBar"
typeset -r PRODUCT_NAME="AgentUsageBar.app"
typeset -r DISPLAY_NAME="Agent Usage Bar"
typeset -r BUNDLE_IDENTIFIER="io.github.sean.AgentUsageBar"
typeset -r OUTPUT_DIRECTORY="$REPOSITORY_ROOT/dist"
typeset -r TRANSACTION_DIRECTORY="$REPOSITORY_ROOT/tmp/release-transactions"

MODE=""
ARGUMENT=""
case "${1:-}" in
    --preflight)
        (( $# == 1 )) || { print -u2 "Usage: $0 --preflight"; exit 2; }
        MODE=preflight
        ;;
    --release-plan)
        (( $# == 2 )) || { print -u2 "Usage: $0 --release-plan <exact-plan.json>"; exit 2; }
        MODE=build
        ARGUMENT=$2
        ;;
    --verify-candidate)
        (( $# == 2 )) || { print -u2 "Usage: $0 --verify-candidate <exact-manifest.json>"; exit 2; }
        MODE=verify
        ARGUMENT=$2
        ;;
    *)
        print -u2 "Full packaging requires the exact release plan created by release.sh prepare."
        print -u2 "Usage: $0 --preflight | --release-plan <plan.json> | --verify-candidate <manifest.json>"
        exit 2
        ;;
esac

if [[ -n "${VERSION_OVERRIDE:-}" || -n "${NO_VERSION_BUMP:-}" \
    || -n "${BUILD_NUMBER_OVERRIDE:-}" || -n "${RELEASE_SUFFIX_OVERRIDE:-}" \
    || -n "${ARCHITECTURE_OVERRIDE:-}" ]]; then
    print -u2 "Version, build, suffix, and architecture overrides are not supported."
    print -u2 "Use scripts/release.sh plan/prepare so metadata is committed and reviewable."
    exit 2
fi

require_tool() {
    [[ "$1" == /* && -f "$1" && -x "$1" ]] \
        || { print -u2 "Required tool is unavailable: $1"; exit 1; }
}

for tool in "$GIT" "$AWK" "$PLUTIL"; do
    require_tool "$tool"
done

assert_repository() {
    local top
    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] \
        || { print -u2 "Packaging requires a Git working tree."; return 1; }
    top=$($GIT -C "$REPOSITORY_ROOT" rev-parse --show-toplevel)
    [[ "${top:A}" == "${REPOSITORY_ROOT:A}" ]] \
        || { print -u2 "Packaging script is not at the repository root."; return 1; }
}

assert_clean_source() {
    [[ -z "$($GIT -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=normal)" ]] || {
        print -u2 "Packaging requires a clean working tree. Commit or remove every change first."
        $GIT -C "$REPOSITORY_ROOT" status --short >&2
        return 1
    }
}

assert_repository

if [[ "$MODE" == "preflight" ]]; then
    assert_clean_source
    aub_read_release_metadata "$REPOSITORY_ROOT/$AUB_VERSION_CONFIG_RELATIVE"
    SOURCE_COMMIT_FULL=$($GIT -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)
    SOURCE_COMMIT=$($GIT -C "$REPOSITORY_ROOT" rev-parse --short=12 HEAD)
    SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE:--}"
    if [[ "$SIGN_IDENTITY" != "-" && "$SIGN_IDENTITY" != "Developer ID Application: "*\(*\) ]]; then
        print -u2 "SIGN_IDENTITY_OVERRIDE must be '-' or a full Developer ID Application identity."
        exit 2
    fi
    print "Packaging preflight passed."
    print "Version: $AUB_MARKETING_VERSION ($AUB_BUILD_NUMBER)"
    print "Release suffix: '${AUB_RELEASE_SUFFIX}'"
    print "Source commit: $SOURCE_COMMIT"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        print "Signing: ad-hoc"
    else
        print "Signing: explicit Developer ID Application identity"
    fi
    exit 0
fi

for tool in "$XCODEBUILD" "$CODESIGN" "$HDIUTIL" "$DITTO" "$SHASUM" \
    "$TAR" "$GREP" "$UNAME" "$MKTEMP" "$LIPO" "$MKDIR" "$LN" \
    "$READLINK" "$STAT" "$MV" "$TRASH"; do
    require_tool "$tool"
done

TEMPORARY_ROOT=$($MKTEMP -d "${TMPDIR:-/tmp}/agent-usage-bar-dmg.XXXXXX")
MOUNT_DIRECTORY="$TEMPORARY_ROOT/mount"
ATTACHED=0

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    if (( ATTACHED )); then
        $HDIUTIL detach "$MOUNT_DIRECTORY" >/dev/null 2>&1 || true
    fi
    if [[ -e "$TEMPORARY_ROOT" ]]; then
        $TRASH "$TEMPORARY_ROOT" >/dev/null 2>&1 \
            || print -u2 "Warning: temporary build directory remains at $TEMPORARY_ROOT"
    fi
    exit "$exit_status"
}
trap cleanup EXIT INT TERM

assert_basename() {
    local value=$1
    local label=$2
    [[ -n "$value" && "$value" == "${value:t}" && "$value" != "." && "$value" != ".." ]] \
        || { print -u2 "$label must be a relative basename without path components."; return 1; }
}

read_candidate_manifest() {
    local manifest=$1
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        || { print -u2 "Candidate manifest must be a regular, non-symlink file: $manifest"; return 1; }
    [[ "$(aub_json_get "$manifest" schemaVersion)" == "1" ]] \
        || { print -u2 "Unsupported candidate manifest schema."; return 1; }

    typeset -g VERSION="$(aub_json_get "$manifest" marketingVersion)"
    typeset -g BUILD_NUMBER="$(aub_json_get "$manifest" buildNumber)"
    typeset -g RELEASE_SUFFIX="$(aub_json_get "$manifest" releaseSuffix)"
    typeset -g RELEASE_VERSION="$(aub_json_get "$manifest" releaseVersion)"
    typeset -g EXPECTED_TAG="$(aub_json_get "$manifest" expectedTag)"
    typeset -g SOURCE_COMMIT_FULL="$(aub_json_get "$manifest" sourceCommit)"
    typeset -g SOURCE_TREE="$(aub_json_get "$manifest" sourceTree)"
    typeset -g ARCHITECTURE="$(aub_json_get "$manifest" architecture)"
    typeset -g MANIFEST_BUNDLE_IDENTIFIER="$(aub_json_get "$manifest" bundleIdentifier)"
    typeset -g DMG_BASENAME="$(aub_json_get "$manifest" dmgBasename)"
    typeset -g DMG_SIZE="$(aub_json_get "$manifest" dmgBytes)"
    typeset -g DMG_SHA256="$(aub_json_get "$manifest" dmgSHA256)"
    typeset -g CHECKSUM_BASENAME="$(aub_json_get "$manifest" checksumBasename)"
    typeset -g SIGNING_MODE="$(aub_json_get "$manifest" signingMode)"
    typeset -g SIGNING_IDENTITY_READBACK="$(aub_json_get "$manifest" signingIdentityReadback)"
    typeset -g NOTARIZED="$(aub_json_get "$manifest" notarized)"

    aub_validate_release_metadata "$VERSION" "$BUILD_NUMBER" "$RELEASE_SUFFIX"
    [[ "$RELEASE_VERSION" == "$(aub_join_release_version "$VERSION" "$RELEASE_SUFFIX")" \
        && "$EXPECTED_TAG" == "v$RELEASE_VERSION" ]] \
        || { print -u2 "Candidate release identity is inconsistent."; return 1; }
    [[ "$SOURCE_COMMIT_FULL" =~ '^[0-9a-f]{40}$' && "$SOURCE_TREE" =~ '^[0-9a-f]{40}$' ]] \
        || { print -u2 "Candidate Git identity is malformed."; return 1; }
    [[ "$ARCHITECTURE" == "arm64" || "$ARCHITECTURE" == "x86_64" ]] \
        || { print -u2 "Candidate architecture is unsupported."; return 1; }
    [[ "$MANIFEST_BUNDLE_IDENTIFIER" == "$BUNDLE_IDENTIFIER" ]] \
        || { print -u2 "Candidate bundle identifier is unexpected."; return 1; }
    [[ "$DMG_SIZE" =~ '^[1-9][0-9]*$' && "$DMG_SHA256" =~ '^[0-9a-f]{64}$' ]] \
        || { print -u2 "Candidate bytes or SHA-256 is malformed."; return 1; }
    [[ "$NOTARIZED" == "false" ]] || { print -u2 "This tooling does not produce notarized candidates."; return 1; }
    assert_basename "$DMG_BASENAME" dmgBasename
    assert_basename "$CHECKSUM_BASENAME" checksumBasename
    [[ "$CHECKSUM_BASENAME" == "$DMG_BASENAME.sha256" ]] \
        || { print -u2 "Candidate checksum basename is inconsistent."; return 1; }
    if [[ "$SIGNING_MODE" == "adhoc" ]]; then
        [[ "$SIGNING_IDENTITY_READBACK" == "adhoc" ]] \
            || { print -u2 "Candidate ad-hoc signer readback is inconsistent."; return 1; }
    elif [[ "$SIGNING_MODE" == "developer-id" ]]; then
        [[ "$SIGNING_IDENTITY_READBACK" == "Developer ID Application: "*\(*\) ]] \
            || { print -u2 "Candidate Developer ID signer is malformed."; return 1; }
    else
        print -u2 "Candidate signing mode is unsupported."
        return 1
    fi
}

verify_app() {
    local app=$1
    local actual_identifier actual_version actual_build actual_suffix actual_source actual_archs signature_details
    actual_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
    actual_suffix=$(/usr/libexec/PlistBuddy -c 'Print :AUBReleaseSuffix' "$app/Contents/Info.plist")
    actual_source=$(/usr/libexec/PlistBuddy -c 'Print :AUBSourceCommit' "$app/Contents/Info.plist")
    actual_archs=$($LIPO -archs "$app/Contents/MacOS/AgentUsageBar")
    [[ "$actual_identifier" == "$BUNDLE_IDENTIFIER" \
        && "$actual_version" == "$VERSION" \
        && "$actual_build" == "$BUILD_NUMBER" \
        && "$actual_suffix" == "$RELEASE_SUFFIX" \
        && "$actual_source" == "${SOURCE_COMMIT_FULL[1,12]}" \
        && "$actual_archs" == "$ARCHITECTURE" ]] \
        || { print -u2 "App metadata or actual CPU architecture does not match the candidate."; return 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app/Contents/Info.plist")" == "true" ]] \
        || { print -u2 "LSUIElement is not set."; return 1; }
    [[ -f "$app/Contents/Resources/AppIcon.icns" ]] \
        || { print -u2 "AppIcon.icns is missing."; return 1; }
    $PLUTIL -lint "$app/Contents/Info.plist" >/dev/null
    $CODESIGN --verify --deep --strict --verbose=2 "$app"
    signature_details=$($CODESIGN -dv --verbose=4 "$app" 2>&1)
    if [[ "$SIGNING_MODE" == "adhoc" ]]; then
        print -r -- "$signature_details" | $GREP -q '^Signature=adhoc$' \
            || { print -u2 "App is not ad-hoc signed as recorded."; return 1; }
    else
        print -r -- "$signature_details" | $GREP -Fq "Authority=$SIGNING_IDENTITY_READBACK" \
            || { print -u2 "App signer does not match the candidate manifest."; return 1; }
    fi
}

verify_candidate() {
    local manifest="${1:A}"
    local directory dmg checksum actual_size actual_sha checksum_line
    read_candidate_manifest "$manifest"
    [[ "${manifest:t}" == "$DMG_BASENAME.candidate.json" ]] \
        || { print -u2 "Candidate manifest filename does not match its DMG identity."; return 1; }
    directory=${manifest:h}
    dmg="$directory/$DMG_BASENAME"
    checksum="$directory/$CHECKSUM_BASENAME"
    [[ -f "$dmg" && ! -L "$dmg" && -f "$checksum" && ! -L "$checksum" ]] \
        || { print -u2 "Candidate DMG or checksum is missing or is a symlink."; return 1; }
    actual_size=$($STAT -f '%z' "$dmg")
    actual_sha=$($SHASUM -a 256 "$dmg" | $AWK '{print $1}')
    checksum_line=$(<"$checksum")
    [[ "$actual_size" == "$DMG_SIZE" && "$actual_sha" == "$DMG_SHA256" \
        && "$checksum_line" == "$DMG_SHA256  $DMG_BASENAME" ]] \
        || { print -u2 "Candidate checksum or byte count does not match its manifest."; return 1; }
    $HDIUTIL verify "$dmg"
    $MKDIR -p "$MOUNT_DIRECTORY"
    $HDIUTIL attach -readonly -nobrowse -mountpoint "$MOUNT_DIRECTORY" "$dmg" >/dev/null
    ATTACHED=1
    [[ -d "$MOUNT_DIRECTORY/$PRODUCT_NAME" && -L "$MOUNT_DIRECTORY/Applications" \
        && "$($READLINK "$MOUNT_DIRECTORY/Applications")" == "/Applications" ]] \
        || { print -u2 "Mounted candidate contents are incomplete."; return 1; }
    verify_app "$MOUNT_DIRECTORY/$PRODUCT_NAME"
    $HDIUTIL detach "$MOUNT_DIRECTORY" >/dev/null
    ATTACHED=0
    print "Candidate verification passed: $DMG_BASENAME"
    print "Version: $RELEASE_VERSION ($BUILD_NUMBER)"
    print "Source commit: $SOURCE_COMMIT_FULL"
    print "SHA-256: $DMG_SHA256"
}

if [[ "$MODE" == "verify" ]]; then
    verify_candidate "$ARGUMENT"
    exit 0
fi

PLAN_PATH="${ARGUMENT:A}"
[[ -f "$PLAN_PATH" && ! -L "$PLAN_PATH" ]] \
    || { print -u2 "Release plan must be a regular, non-symlink file: $ARGUMENT"; exit 1; }
[[ "$(aub_json_get "$PLAN_PATH" schemaVersion)" == "1" \
    && "$(aub_json_get "$PLAN_PATH" state)" == "prepared" ]] \
    || { print -u2 "Release plan is unsupported or already consumed; it will not be replayed."; exit 1; }

SOURCE_COMMIT_FULL="$(aub_json_get "$PLAN_PATH" sourceCommit)"
SOURCE_TREE="$(aub_json_get "$PLAN_PATH" sourceTree)"
BASE_COMMIT="$(aub_json_get "$PLAN_PATH" baseCommit)"
VERSION="$(aub_json_get "$PLAN_PATH" marketingVersion)"
BUILD_NUMBER="$(aub_json_get "$PLAN_PATH" buildNumber)"
RELEASE_SUFFIX="$(aub_json_get "$PLAN_PATH" releaseSuffix)"
RELEASE_VERSION="$(aub_json_get "$PLAN_PATH" releaseVersion)"
EXPECTED_TAG="$(aub_json_get "$PLAN_PATH" expectedTag)"
ARCHITECTURE="$(aub_json_get "$PLAN_PATH" architecture)"
DMG_BASENAME="$(aub_json_get "$PLAN_PATH" dmgBasename)"
CHECKSUM_BASENAME="$(aub_json_get "$PLAN_PATH" checksumBasename)"
MANIFEST_BASENAME="$(aub_json_get "$PLAN_PATH" manifestBasename)"
SIGN_IDENTITY="$(aub_json_get "$PLAN_PATH" signingIdentity)"

[[ "${PLAN_PATH:h}" == "${TRANSACTION_DIRECTORY:A}" \
    && "${PLAN_PATH:t}" == "$SOURCE_COMMIT_FULL.json" ]] \
    || { print -u2 "Release plan is not the exact repo-local transaction for its source commit."; exit 1; }

aub_validate_release_metadata "$VERSION" "$BUILD_NUMBER" "$RELEASE_SUFFIX"
[[ "$RELEASE_VERSION" == "$(aub_join_release_version "$VERSION" "$RELEASE_SUFFIX")" \
    && "$EXPECTED_TAG" == "v$RELEASE_VERSION" \
    && ( "$ARCHITECTURE" == "arm64" || "$ARCHITECTURE" == "x86_64" ) ]] \
    || { print -u2 "Release plan identity is inconsistent."; exit 1; }
assert_basename "$DMG_BASENAME" dmgBasename
assert_basename "$CHECKSUM_BASENAME" checksumBasename
assert_basename "$MANIFEST_BASENAME" manifestBasename
[[ "$DMG_BASENAME" == "Agent-Usage-Bar-$RELEASE_VERSION-b$BUILD_NUMBER-$ARCHITECTURE.dmg" \
    && "$CHECKSUM_BASENAME" == "$DMG_BASENAME.sha256" \
    && "$MANIFEST_BASENAME" == "$DMG_BASENAME.candidate.json" ]] \
    || { print -u2 "Release plan output basenames are inconsistent."; exit 1; }
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGNING_MODE=adhoc
    SIGNING_IDENTITY_READBACK=adhoc
elif [[ "$SIGN_IDENTITY" == "Developer ID Application: "*\(*\) ]]; then
    SIGNING_MODE=developer-id
    SIGNING_IDENTITY_READBACK=$SIGN_IDENTITY
else
    print -u2 "Release plan signing identity is unsupported."
    exit 1
fi

assert_clean_source
[[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$SOURCE_COMMIT_FULL" \
    && "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^{tree})" == "$SOURCE_TREE" ]] \
    || { print -u2 "Current Git source does not match the release plan."; exit 1; }
[[ "$($GIT -C "$REPOSITORY_ROOT" branch --show-current)" == "main" \
    && "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^)" == "$BASE_COMMIT" \
    && "$($GIT -C "$REPOSITORY_ROOT" diff-tree --no-commit-id --name-only -r HEAD)" == "$AUB_VERSION_CONFIG_RELATIVE" \
    && "$($GIT -C "$REPOSITORY_ROOT" log -1 --format=%s)" == "release: prepare $EXPECTED_TAG" ]] \
    || { print -u2 "Source commit is not the exact release metadata transaction."; exit 1; }

COMMITTED_VERSION_FILE="$TEMPORARY_ROOT/Version.xcconfig"
$GIT -C "$REPOSITORY_ROOT" show "$SOURCE_COMMIT_FULL:$AUB_VERSION_CONFIG_RELATIVE" > "$COMMITTED_VERSION_FILE"
aub_read_release_metadata "$COMMITTED_VERSION_FILE"
[[ "$AUB_MARKETING_VERSION" == "$VERSION" && "$AUB_BUILD_NUMBER" == "$BUILD_NUMBER" \
    && "$AUB_RELEASE_SUFFIX" == "$RELEASE_SUFFIX" ]] \
    || { print -u2 "Committed version metadata does not match the release plan."; exit 1; }

$MKDIR -p "$OUTPUT_DIRECTORY"
DMG_PATH="$OUTPUT_DIRECTORY/$DMG_BASENAME"
CHECKSUM_PATH="$OUTPUT_DIRECTORY/$CHECKSUM_BASENAME"
MANIFEST_PATH="$OUTPUT_DIRECTORY/$MANIFEST_BASENAME"
for output in "$DMG_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH"; do
    [[ ! -e "$output" ]] || { print -u2 "Existing output will not be replaced: $output"; exit 1; }
done

# Claim the one-shot transaction before the expensive build. If the process dies after
# this point, the plan stays 'executing' and a person must inspect the evidence rather
# than replaying a mutation whose outcome is unknown.
PLAN_TEMPORARY="$PLAN_PATH.tmp.$$"
PLAN_BUILDER="$TEMPORARY_ROOT/plan-state.plist"
$PLUTIL -convert xml1 -o "$PLAN_BUILDER" "$PLAN_PATH"
$PLUTIL -replace state -string executing "$PLAN_BUILDER"
$PLUTIL -convert json -o "$PLAN_TEMPORARY" "$PLAN_BUILDER"
$MV "$PLAN_TEMPORARY" "$PLAN_PATH"

BUILD_SOURCE_ROOT="$TEMPORARY_ROOT/source"
DERIVED_DATA="$TEMPORARY_ROOT/DerivedData"
STAGING_DIRECTORY="$TEMPORARY_ROOT/staging"
$MKDIR -p "$BUILD_SOURCE_ROOT" "$STAGING_DIRECTORY" "$MOUNT_DIRECTORY"
$GIT -C "$REPOSITORY_ROOT" archive --format=tar "$SOURCE_COMMIT_FULL" \
    | $TAR -xf - -C "$BUILD_SOURCE_ROOT"
BUILD_PROJECT_PATH="$BUILD_SOURCE_ROOT/$PROJECT_RELATIVE_PATH"
[[ -f "$BUILD_PROJECT_PATH/project.pbxproj" ]] \
    || { print -u2 "Tracked source export does not contain the Xcode project."; exit 1; }

print "Building $DISPLAY_NAME $RELEASE_VERSION ($BUILD_NUMBER) from ${SOURCE_COMMIT_FULL[1,12]} for $ARCHITECTURE…"
$XCODEBUILD \
    -quiet \
    -project "$BUILD_PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS,arch=$ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    AUB_RELEASE_SUFFIX="$RELEASE_SUFFIX" \
    AUB_SOURCE_COMMIT="${SOURCE_COMMIT_FULL[1,12]}" \
    ARCHS="$ARCHITECTURE" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGNING_ALLOWED=YES \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$PRODUCT_NAME"
[[ -d "$BUILT_APP" ]] || { print -u2 "Release app was not produced."; exit 1; }
verify_app "$BUILT_APP"

$DITTO "$BUILT_APP" "$STAGING_DIRECTORY/$PRODUCT_NAME"
$LN -s /Applications "$STAGING_DIRECTORY/Applications"
TEMPORARY_DMG="$TEMPORARY_ROOT/$DMG_BASENAME"
TEMPORARY_CHECKSUM="$TEMPORARY_ROOT/$CHECKSUM_BASENAME"
TEMPORARY_MANIFEST="$TEMPORARY_ROOT/$MANIFEST_BASENAME"

$HDIUTIL create -volname "$DISPLAY_NAME $VERSION" -srcfolder "$STAGING_DIRECTORY" -format UDZO "$TEMPORARY_DMG"
$HDIUTIL verify "$TEMPORARY_DMG"
$HDIUTIL attach -readonly -nobrowse -mountpoint "$MOUNT_DIRECTORY" "$TEMPORARY_DMG" >/dev/null
ATTACHED=1
[[ -d "$MOUNT_DIRECTORY/$PRODUCT_NAME" && -L "$MOUNT_DIRECTORY/Applications" \
    && "$($READLINK "$MOUNT_DIRECTORY/Applications")" == "/Applications" ]] \
    || { print -u2 "Mounted DMG does not contain the expected app and Applications link."; exit 1; }
verify_app "$MOUNT_DIRECTORY/$PRODUCT_NAME"
$HDIUTIL detach "$MOUNT_DIRECTORY" >/dev/null
ATTACHED=0

DMG_SIZE=$($STAT -f '%z' "$TEMPORARY_DMG")
DMG_SHA256=$($SHASUM -a 256 "$TEMPORARY_DMG" | $AWK '{print $1}')
print -r -- "$DMG_SHA256  $DMG_BASENAME" > "$TEMPORARY_CHECKSUM"

$PLUTIL -create xml1 "$TEMPORARY_ROOT/candidate-manifest.plist"
MANIFEST_BUILDER="$TEMPORARY_ROOT/candidate-manifest.plist"
aub_json_put_integer "$MANIFEST_BUILDER" schemaVersion 1
aub_json_put_string "$MANIFEST_BUILDER" releaseVersion "$RELEASE_VERSION"
aub_json_put_string "$MANIFEST_BUILDER" marketingVersion "$VERSION"
aub_json_put_integer "$MANIFEST_BUILDER" buildNumber "$BUILD_NUMBER"
aub_json_put_string "$MANIFEST_BUILDER" releaseSuffix "$RELEASE_SUFFIX"
aub_json_put_string "$MANIFEST_BUILDER" expectedTag "$EXPECTED_TAG"
aub_json_put_string "$MANIFEST_BUILDER" sourceCommit "$SOURCE_COMMIT_FULL"
aub_json_put_string "$MANIFEST_BUILDER" sourceTree "$SOURCE_TREE"
aub_json_put_string "$MANIFEST_BUILDER" architecture "$ARCHITECTURE"
aub_json_put_string "$MANIFEST_BUILDER" bundleIdentifier "$BUNDLE_IDENTIFIER"
aub_json_put_string "$MANIFEST_BUILDER" dmgBasename "$DMG_BASENAME"
aub_json_put_integer "$MANIFEST_BUILDER" dmgBytes "$DMG_SIZE"
aub_json_put_string "$MANIFEST_BUILDER" dmgSHA256 "$DMG_SHA256"
aub_json_put_string "$MANIFEST_BUILDER" checksumBasename "$CHECKSUM_BASENAME"
aub_json_put_string "$MANIFEST_BUILDER" signingMode "$SIGNING_MODE"
aub_json_put_string "$MANIFEST_BUILDER" signingIdentityReadback "$SIGNING_IDENTITY_READBACK"
aub_json_put_boolean "$MANIFEST_BUILDER" notarized false
$PLUTIL -convert json -o "$TEMPORARY_MANIFEST" "$MANIFEST_BUILDER"
read_candidate_manifest "$TEMPORARY_MANIFEST"

[[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$SOURCE_COMMIT_FULL" \
    && "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^{tree})" == "$SOURCE_TREE" ]] \
    || { print -u2 "Git source changed while packaging."; exit 1; }
assert_clean_source
for output in "$DMG_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH"; do
    [[ ! -e "$output" ]] || { print -u2 "Output collision occurred during the build: $output"; exit 1; }
done

# Publish supporting evidence first and the installable DMG last. -n plus source-file
# readback makes a late collision fail closed on macOS instead of overwriting it.
$MV -n "$TEMPORARY_CHECKSUM" "$CHECKSUM_PATH"
[[ ! -e "$TEMPORARY_CHECKSUM" ]] || { print -u2 "Checksum publication collided."; exit 1; }
$MV -n "$TEMPORARY_MANIFEST" "$MANIFEST_PATH"
[[ ! -e "$TEMPORARY_MANIFEST" ]] || { print -u2 "Manifest publication collided."; exit 1; }
$MV -n "$TEMPORARY_DMG" "$DMG_PATH"
[[ ! -e "$TEMPORARY_DMG" ]] || { print -u2 "DMG publication collided."; exit 1; }

verify_candidate "$MANIFEST_PATH"
MANIFEST_SHA256=$($SHASUM -a 256 "$MANIFEST_PATH" | $AWK '{print $1}')
PLAN_TEMPORARY="$PLAN_PATH.tmp.$$"
$PLUTIL -convert xml1 -o "$PLAN_BUILDER" "$PLAN_PATH"
$PLUTIL -replace state -string packaged "$PLAN_BUILDER"
$PLUTIL -insert dmgBytes -integer "$DMG_SIZE" "$PLAN_BUILDER"
$PLUTIL -insert dmgSHA256 -string "$DMG_SHA256" "$PLAN_BUILDER"
$PLUTIL -insert manifestSHA256 -string "$MANIFEST_SHA256" "$PLAN_BUILDER"
$PLUTIL -convert json -o "$PLAN_TEMPORARY" "$PLAN_BUILDER"
$MV "$PLAN_TEMPORARY" "$PLAN_PATH"

print ""
print "DMG ready: $DMG_PATH"
print "Checksum: $CHECKSUM_PATH"
print "Manifest: $MANIFEST_PATH"
print "No tag, push, remote release, or installation was performed."
