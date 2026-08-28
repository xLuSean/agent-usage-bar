#!/bin/zsh

# The only supported entry point for creating and finalizing a release candidate.
# It never pushes, installs the app, talks to GitHub, or calls either usage provider.

set -euo pipefail

typeset -r GIT=/usr/bin/git
typeset -r PLUTIL=/usr/bin/plutil
typeset -r SHASUM=/usr/bin/shasum
typeset -r MKTEMP=/usr/bin/mktemp
typeset -r MKDIR=/bin/mkdir
typeset -r MV=/bin/mv
typeset -r TRASH=/usr/bin/trash

unset DEVELOPER_DIR TOOLCHAINS SDKROOT

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
source "$SCRIPT_DIR/release_common.zsh"

typeset -r TRANSACTION_DIRECTORY="$REPOSITORY_ROOT/tmp/release-transactions"
typeset -r RELEASE_LOCK="$REPOSITORY_ROOT/tmp/release.lock"

COMMAND="${1:-}"
if (( $# > 0 )); then
    shift
fi
NEXT_MINOR=0
MAKE_FINAL=0
ARCHITECTURE="$(/usr/bin/uname -m)"
MANIFEST_ARGUMENT=""

usage() {
    print -u2 "Usage:"
    print -u2 "  $0 plan [--next-minor] [--final] [--architecture arm64|x86_64]"
    print -u2 "  $0 prepare [--next-minor] [--final] [--architecture arm64|x86_64]"
    print -u2 "  $0 finalize <exact-candidate-manifest.json>"
}

require_tool() {
    [[ "$1" == /* && -f "$1" && -x "$1" ]] \
        || { print -u2 "Required tool is unavailable: $1"; exit 1; }
}

for tool in "$GIT" "$PLUTIL" "$SHASUM" "$MKTEMP" "$MKDIR" "$MV" "$TRASH"; do
    require_tool "$tool"
done

case "$COMMAND" in
    plan|prepare)
        while (( $# > 0 )); do
            case "$1" in
                --next-minor) NEXT_MINOR=1 ;;
                --final) MAKE_FINAL=1 ;;
                --architecture)
                    (( $# >= 2 )) || { usage; exit 2; }
                    ARCHITECTURE=$2
                    shift
                    ;;
                *) print -u2 "Unknown argument: $1"; usage; exit 2 ;;
            esac
            shift
        done
        ;;
    finalize)
        (( $# == 1 )) || { usage; exit 2; }
        MANIFEST_ARGUMENT=$1
        ;;
    *) usage; exit 2 ;;
esac

if [[ "$ARCHITECTURE" != "arm64" && "$ARCHITECTURE" != "x86_64" ]]; then
    print -u2 "Architecture must be arm64 or x86_64."
    exit 2
fi

assert_repository_root() {
    local top
    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] \
        || { print -u2 "Release requires a Git working tree."; return 1; }
    top=$($GIT -C "$REPOSITORY_ROOT" rev-parse --show-toplevel)
    [[ "${top:A}" == "${REPOSITORY_ROOT:A}" ]] \
        || { print -u2 "release.sh is not at the repository root."; return 1; }
}

assert_no_git_operation() {
    local git_dir marker
    git_dir=$($GIT -C "$REPOSITORY_ROOT" rev-parse --git-dir)
    [[ "$git_dir" == /* ]] || git_dir="$REPOSITORY_ROOT/$git_dir"
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply BISECT_LOG; do
        [[ ! -e "$git_dir/$marker" ]] || {
            print -u2 "An unfinished Git operation is present: $marker"
            return 1
        }
    done
}

assert_main_clean() {
    local branch dirty
    branch=$($GIT -C "$REPOSITORY_ROOT" branch --show-current)
    [[ "$branch" == "main" ]] || { print -u2 "Release requires branch main (found ${branch:-detached HEAD})."; return 1; }
    dirty=$($GIT -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=normal)
    [[ -z "$dirty" ]] || {
        print -u2 "Release requires a clean working tree."
        $GIT -C "$REPOSITORY_ROOT" status --short >&2
        return 1
    }
    assert_no_git_operation
}

assert_repo_identity() {
    typeset -g AUB_AUTHOR_NAME="$($GIT -C "$REPOSITORY_ROOT" config --local --get user.name 2>/dev/null || true)"
    typeset -g AUB_AUTHOR_EMAIL="$($GIT -C "$REPOSITORY_ROOT" config --local --get user.email 2>/dev/null || true)"
    [[ -n "$AUB_AUTHOR_NAME" && -n "$AUB_AUTHOR_EMAIL" ]] || {
        print -u2 "Set repo-local user.name and user.email before releasing."
        return 1
    }
}

read_signing_policy() {
    typeset -g AUB_SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE:--}"
    if [[ "$AUB_SIGN_IDENTITY" != "-" \
        && "$AUB_SIGN_IDENTITY" != "Developer ID Application: "*\(*\) ]]; then
        print -u2 "SIGN_IDENTITY_OVERRIDE must be '-' or a full Developer ID Application identity."
        return 1
    fi
    if [[ "$AUB_SIGN_IDENTITY" == "-" ]]; then
        typeset -g AUB_SIGNING_MODE="adhoc"
    else
        typeset -g AUB_SIGNING_MODE="developer-id"
    fi
}

prepare_context() {
    assert_repository_root
    assert_main_clean
    assert_repo_identity
    read_signing_policy
    aub_read_release_metadata "$REPOSITORY_ROOT/$AUB_VERSION_CONFIG_RELATIVE"
    aub_compute_next_release "$NEXT_MINOR" "$MAKE_FINAL"

    typeset -g AUB_BASE_COMMIT="$($GIT -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
    typeset -g AUB_BASE_TREE="$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^{tree})"
    typeset -g AUB_TARGET_RELEASE_VERSION="$(aub_join_release_version "$AUB_TARGET_MARKETING_VERSION" "$AUB_TARGET_RELEASE_SUFFIX")"
    typeset -g AUB_EXPECTED_TAG="v$AUB_TARGET_RELEASE_VERSION"
    typeset -g AUB_DMG_BASENAME="Agent-Usage-Bar-$AUB_TARGET_RELEASE_VERSION-b$AUB_TARGET_BUILD_NUMBER-$ARCHITECTURE.dmg"
    typeset -g AUB_CHECKSUM_BASENAME="$AUB_DMG_BASENAME.sha256"
    typeset -g AUB_MANIFEST_BASENAME="$AUB_DMG_BASENAME.candidate.json"

    if $GIT -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/tags/$AUB_EXPECTED_TAG"; then
        print -u2 "Tag already exists: $AUB_EXPECTED_TAG"
        return 1
    fi
    local basename
    for basename in "$AUB_DMG_BASENAME" "$AUB_CHECKSUM_BASENAME" "$AUB_MANIFEST_BASENAME"; do
        [[ ! -e "$REPOSITORY_ROOT/dist/$basename" ]] || {
            print -u2 "Release output already exists and will not be replaced: dist/$basename"
            return 1
        }
    done
}

print_plan() {
    print "Release plan (read-only)"
    print "Repository: $REPOSITORY_ROOT"
    print "Branch: main"
    print "Base commit: $AUB_BASE_COMMIT"
    print "Base tree: $AUB_BASE_TREE"
    print "Commit identity: $AUB_AUTHOR_NAME <$AUB_AUTHOR_EMAIL>"
    print "Current: $AUB_MARKETING_VERSION ($AUB_BUILD_NUMBER), suffix '${AUB_RELEASE_SUFFIX}'"
    print "Target: $AUB_TARGET_MARKETING_VERSION ($AUB_TARGET_BUILD_NUMBER), suffix '${AUB_TARGET_RELEASE_SUFFIX}'"
    print "Commit: release: prepare $AUB_EXPECTED_TAG"
    print "Tag after human approval: $AUB_EXPECTED_TAG"
    print "DMG: dist/$AUB_DMG_BASENAME"
    print "Checksum: dist/$AUB_CHECKSUM_BASENAME"
    print "Manifest: dist/$AUB_MANIFEST_BASENAME"
    print "Only source change: $AUB_VERSION_CONFIG_RELATIVE"
    print "Architecture: $ARCHITECTURE"
    print "Signing: $AUB_SIGNING_MODE (not notarized)"
    print "No output collision found. Nothing was changed."
}

acquire_lock() {
    $MKDIR -p "$REPOSITORY_ROOT/tmp"
    if ! $MKDIR "$RELEASE_LOCK" 2>/dev/null; then
        print -u2 "Another release operation may be active. Lock retained at: $RELEASE_LOCK"
        print -u2 "Inspect it manually; this tool never deletes a pre-existing lock."
        return 1
    fi
    print -r -- "pid=$$" > "$RELEASE_LOCK/owner"
    print -r -- "command=$COMMAND" >> "$RELEASE_LOCK/owner"
    typeset -g AUB_LOCK_OWNED=1
}

release_lock_cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    if (( ${AUB_LOCK_OWNED:-0} )) && [[ -e "$RELEASE_LOCK" ]]; then
        $TRASH "$RELEASE_LOCK" >/dev/null 2>&1 \
            || print -u2 "Warning: release lock remains at $RELEASE_LOCK"
    fi
    exit "$exit_status"
}

write_version_config() {
    local temporary
    temporary=$($MKTEMP "$REPOSITORY_ROOT/macos/AgentUsageBar/App/AgentUsageBar/Config/.Version.xcconfig.XXXXXX")
    {
        print "// Release identity. This is the single committed source for every build configuration."
        print "// New installable candidates are authored only by scripts/release.sh."
        print "MARKETING_VERSION = $AUB_TARGET_MARKETING_VERSION"
        print "CURRENT_PROJECT_VERSION = $AUB_TARGET_BUILD_NUMBER"
        print "AUB_RELEASE_SUFFIX = $AUB_TARGET_RELEASE_SUFFIX"
    } > "$temporary"
    $MV "$temporary" "$REPOSITORY_ROOT/$AUB_VERSION_CONFIG_RELATIVE"
    aub_read_release_metadata "$REPOSITORY_ROOT/$AUB_VERSION_CONFIG_RELATIVE"
    [[ "$AUB_MARKETING_VERSION" == "$AUB_TARGET_MARKETING_VERSION" \
        && "$AUB_BUILD_NUMBER" == "$AUB_TARGET_BUILD_NUMBER" \
        && "$AUB_RELEASE_SUFFIX" == "$AUB_TARGET_RELEASE_SUFFIX" ]] \
        || { print -u2 "Version metadata readback failed."; return 1; }
}

assert_only_version_diff() {
    local unstaged staged untracked
    unstaged=$($GIT -C "$REPOSITORY_ROOT" diff --name-only)
    staged=$($GIT -C "$REPOSITORY_ROOT" diff --cached --name-only)
    untracked=$($GIT -C "$REPOSITORY_ROOT" ls-files --others --exclude-standard)
    [[ "$unstaged" == "$AUB_VERSION_CONFIG_RELATIVE" && -z "$staged" && -z "$untracked" ]] || {
        print -u2 "Verification left changes outside the exact release metadata file."
        $GIT -C "$REPOSITORY_ROOT" status --short >&2
        return 1
    }
}

write_release_plan() {
    local plan_path=$1
    local temporary="$plan_path.tmp.$$"
    local builder_directory=$($MKTEMP -d "${TMPDIR:-/tmp}/agent-usage-bar-plan.XXXXXX")
    local builder="$builder_directory/plan.plist"
    $PLUTIL -create xml1 "$builder"
    aub_json_put_integer "$builder" schemaVersion 1
    aub_json_put_string "$builder" state prepared
    aub_json_put_string "$builder" baseCommit "$AUB_BASE_COMMIT"
    aub_json_put_string "$builder" sourceCommit "$AUB_RELEASE_COMMIT"
    aub_json_put_string "$builder" sourceTree "$AUB_RELEASE_TREE"
    aub_json_put_string "$builder" marketingVersion "$AUB_TARGET_MARKETING_VERSION"
    aub_json_put_integer "$builder" buildNumber "$AUB_TARGET_BUILD_NUMBER"
    aub_json_put_string "$builder" releaseSuffix "$AUB_TARGET_RELEASE_SUFFIX"
    aub_json_put_string "$builder" releaseVersion "$AUB_TARGET_RELEASE_VERSION"
    aub_json_put_string "$builder" expectedTag "$AUB_EXPECTED_TAG"
    aub_json_put_string "$builder" architecture "$ARCHITECTURE"
    aub_json_put_string "$builder" dmgBasename "$AUB_DMG_BASENAME"
    aub_json_put_string "$builder" checksumBasename "$AUB_CHECKSUM_BASENAME"
    aub_json_put_string "$builder" manifestBasename "$AUB_MANIFEST_BASENAME"
    aub_json_put_string "$builder" signingIdentity "$AUB_SIGN_IDENTITY"
    $PLUTIL -convert json -o "$temporary" "$builder"
    $MV "$temporary" "$plan_path"
    $TRASH "$builder_directory" >/dev/null 2>&1 \
        || print -u2 "Warning: temporary plan builder remains at $builder_directory"
}

run_prepare() {
    acquire_lock
    trap release_lock_cleanup EXIT INT TERM
    prepare_context
    print_plan

    write_version_config
    "$REPOSITORY_ROOT/scripts/verify.sh"
    assert_only_version_diff

    $GIT -C "$REPOSITORY_ROOT" add -- "$AUB_VERSION_CONFIG_RELATIVE"
    $GIT -C "$REPOSITORY_ROOT" diff --cached --quiet --exit-code \
        && { print -u2 "No release metadata change was staged."; return 1; }
    $GIT -C "$REPOSITORY_ROOT" commit -m "release: prepare $AUB_EXPECTED_TAG"

    typeset -g AUB_RELEASE_COMMIT="$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD)"
    typeset -g AUB_RELEASE_TREE="$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^{tree})"
    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^)" == "$AUB_BASE_COMMIT" ]] \
        || { print -u2 "Release commit parent drifted."; return 1; }
    [[ "$($GIT -C "$REPOSITORY_ROOT" diff-tree --no-commit-id --name-only -r HEAD)" == "$AUB_VERSION_CONFIG_RELATIVE" ]] \
        || { print -u2 "Release commit contains an unexpected path."; return 1; }
    assert_main_clean
    aub_read_release_metadata "$REPOSITORY_ROOT/$AUB_VERSION_CONFIG_RELATIVE"
    [[ "$AUB_MARKETING_VERSION" == "$AUB_TARGET_MARKETING_VERSION" \
        && "$AUB_BUILD_NUMBER" == "$AUB_TARGET_BUILD_NUMBER" \
        && "$AUB_RELEASE_SUFFIX" == "$AUB_TARGET_RELEASE_SUFFIX" ]] \
        || { print -u2 "Committed metadata does not match the frozen plan."; return 1; }

    $MKDIR -p "$TRANSACTION_DIRECTORY"
    local plan_path="$TRANSACTION_DIRECTORY/$AUB_RELEASE_COMMIT.json"
    [[ ! -e "$plan_path" ]] || { print -u2 "Release transaction already exists: $plan_path"; return 1; }
    write_release_plan "$plan_path"
    "$REPOSITORY_ROOT/scripts/package_dmg.sh" --release-plan "$plan_path"

    print ""
    print "Candidate created, but no tag or remote release was created."
    print "Install and test the exact DMG, then finalize its exact manifest:"
    print "  ./scripts/release.sh finalize dist/$AUB_MANIFEST_BASENAME"
}

run_finalize() {
    acquire_lock
    trap release_lock_cleanup EXIT INT TERM
    assert_repository_root
    assert_main_clean

    local manifest="${MANIFEST_ARGUMENT:A}"
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        || { print -u2 "Manifest must be a regular, non-symlink file: $MANIFEST_ARGUMENT"; return 1; }
    [[ "${manifest:h}" == "${REPOSITORY_ROOT:A}/dist" ]] \
        || { print -u2 "Finalize only accepts the exact candidate manifest from dist/."; return 1; }
    "$REPOSITORY_ROOT/scripts/package_dmg.sh" --verify-candidate "$manifest"

    local source_commit expected_tag release_version build_number source_tree dmg_basename dmg_bytes dmg_sha architecture checksum_basename
    source_commit=$(aub_json_get "$manifest" sourceCommit)
    source_tree=$(aub_json_get "$manifest" sourceTree)
    expected_tag=$(aub_json_get "$manifest" expectedTag)
    release_version=$(aub_json_get "$manifest" releaseVersion)
    build_number=$(aub_json_get "$manifest" buildNumber)
    dmg_basename=$(aub_json_get "$manifest" dmgBasename)
    dmg_bytes=$(aub_json_get "$manifest" dmgBytes)
    dmg_sha=$(aub_json_get "$manifest" dmgSHA256)
    architecture=$(aub_json_get "$manifest" architecture)
    checksum_basename=$(aub_json_get "$manifest" checksumBasename)

    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$source_commit" ]] \
        || { print -u2 "HEAD is not the candidate source commit."; return 1; }
    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-parse HEAD^{tree})" == "$source_tree" ]] \
        || { print -u2 "HEAD tree is not the candidate source tree."; return 1; }
    [[ "$expected_tag" == "v$release_version" ]] \
        || { print -u2 "Manifest tag and release version disagree."; return 1; }

    local annotation
    annotation="Agent Usage Bar $release_version
Build: $build_number
Architecture: $architecture
Source commit: $source_commit
Source tree: $source_tree
DMG: $dmg_basename
Bytes: $dmg_bytes
SHA-256: $dmg_sha"

    if $GIT -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/tags/$expected_tag"; then
        local tagged_commit existing_annotation
        tagged_commit=$($GIT -C "$REPOSITORY_ROOT" rev-list -n 1 "$expected_tag")
        existing_annotation=$($GIT -C "$REPOSITORY_ROOT" tag -l "$expected_tag" --format='%(contents)')
        [[ "$($GIT -C "$REPOSITORY_ROOT" cat-file -t "refs/tags/$expected_tag")" == "tag" \
            && "$tagged_commit" == "$source_commit" && "$existing_annotation" == "$annotation" ]] \
            || { print -u2 "Existing tag disagrees with the candidate and will not be moved."; return 1; }
        print "Candidate was already finalized as $expected_tag. Nothing changed."
        return 0
    fi

    # Creating the tag requires the ignored transaction. Once the exact annotated tag
    # exists, the tag annotation plus the independently reverified candidate above is
    # the durable idempotency record; cleaning tmp/ must not break a safe readback.
    local transaction="$TRANSACTION_DIRECTORY/$source_commit.json"
    [[ -f "$transaction" && ! -L "$transaction" ]] \
        || { print -u2 "Packaged release transaction is missing: $transaction"; return 1; }
    [[ "$(aub_json_get "$transaction" schemaVersion)" == "1" \
        && "$(aub_json_get "$transaction" state)" == "packaged" \
        && "$(aub_json_get "$transaction" sourceCommit)" == "$source_commit" \
        && "$(aub_json_get "$transaction" sourceTree)" == "$source_tree" \
        && "$(aub_json_get "$transaction" expectedTag)" == "$expected_tag" \
        && "$(aub_json_get "$transaction" releaseVersion)" == "$release_version" \
        && "$(aub_json_get "$transaction" buildNumber)" == "$build_number" \
        && "$(aub_json_get "$transaction" architecture)" == "$architecture" \
        && "$(aub_json_get "$transaction" dmgBasename)" == "$dmg_basename" \
        && "$(aub_json_get "$transaction" checksumBasename)" == "$checksum_basename" \
        && "$(aub_json_get "$transaction" manifestBasename)" == "${manifest:t}" \
        && "$(aub_json_get "$transaction" dmgBytes)" == "$dmg_bytes" \
        && "$(aub_json_get "$transaction" dmgSHA256)" == "$dmg_sha" \
        && "$(aub_json_get "$transaction" manifestSHA256)" == "$($SHASUM -a 256 "$manifest" | /usr/bin/awk '{print $1}')" ]] \
        || { print -u2 "Candidate does not match its packaged release transaction."; return 1; }

    $GIT -C "$REPOSITORY_ROOT" tag -a "$expected_tag" -m "$annotation"
    [[ "$($GIT -C "$REPOSITORY_ROOT" rev-list -n 1 "$expected_tag")" == "$source_commit" ]] \
        || { print -u2 "Tag readback did not point to the candidate commit."; return 1; }
    print "Created local annotated tag: $expected_tag"
    print "Nothing was pushed or published remotely."
}

case "$COMMAND" in
    plan) prepare_context; print_plan ;;
    prepare) run_prepare ;;
    finalize) run_finalize ;;
esac
