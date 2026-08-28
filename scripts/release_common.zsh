#!/bin/zsh

# Shared, deterministic release-metadata parsing. This file performs no mutation and is
# sourced only by the tracked release scripts beside it.

typeset -gr AUB_VERSION_CONFIG_RELATIVE="macos/AgentUsageBar/App/AgentUsageBar/Config/Version.xcconfig"
typeset -gr AUB_PUBLIC_BUILD_FLOOR=4100
typeset -gr AUB_MAX_BUILD_NUMBER=9999

aub_fail() {
    print -u2 -- "$*"
    return 1
}

aub_xcconfig_key_count() {
    local file=$1
    local wanted=$2
    /usr/bin/awk -F= -v wanted="$wanted" '
        /^[[:space:]]*(\/\/|$)/ { next }
        {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) count += 1
        }
        END { print count + 0 }
    ' "$file"
}

aub_xcconfig_value() {
    local file=$1
    local wanted=$2
    /usr/bin/awk -F= -v wanted="$wanted" '
        /^[[:space:]]*(\/\/|$)/ { next }
        {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) {
                sub(/^[^=]*=/, "", $0)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                print $0
                exit
            }
        }
    ' "$file"
}

aub_validate_release_metadata() {
    local version=$1
    local build=$2
    local suffix=$3
    local -a version_parts suffix_parts
    local part

    if [[ ! "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
        aub_fail "MARKETING_VERSION must be three non-negative integers without leading zeros: $version"
        return 1
    fi
    if [[ ! "$build" =~ '^[1-9][0-9]*$' ]] \
        || (( build < 1 || build > AUB_MAX_BUILD_NUMBER )); then
        aub_fail "CURRENT_PROJECT_VERSION must be 1...$AUB_MAX_BUILD_NUMBER: $build"
        return 1
    fi
    if [[ -n "$suffix" ]]; then
        if [[ ! "$suffix" =~ '^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$' ]]; then
            aub_fail "AUB_RELEASE_SUFFIX is not a valid pre-release suffix: $suffix"
            return 1
        fi
        suffix_parts=(${(s:.:)suffix})
        for part in "${suffix_parts[@]}"; do
            if [[ "$part" =~ '^[0-9]+$' && ${#part} -gt 1 && "$part" == 0* ]]; then
                aub_fail "Numeric pre-release identifiers cannot have leading zeros: $suffix"
                return 1
            fi
        done
    fi

    version_parts=(${(s:.:)version})
    if (( version_parts[3] > 999 )); then
        aub_fail "The release patch is outside the approved 0...999 range: $version"
        return 1
    fi
}

aub_read_release_metadata() {
    local file=$1
    local key count
    local unknown

    if [[ ! -f "$file" || -L "$file" ]]; then
        aub_fail "Release metadata must be a regular, non-symlink file: $file"
        return 1
    fi

    unknown=$(/usr/bin/awk -F= '
        /^[[:space:]]*(\/\/|$)/ { next }
        {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != "MARKETING_VERSION" \
                && key != "CURRENT_PROJECT_VERSION" \
                && key != "AUB_RELEASE_SUFFIX") print key
        }
    ' "$file")
    if [[ -n "$unknown" ]]; then
        aub_fail "Version.xcconfig contains unknown assignments: ${(j:, :)${(f)unknown}}"
        return 1
    fi

    for key in MARKETING_VERSION CURRENT_PROJECT_VERSION AUB_RELEASE_SUFFIX; do
        count=$(aub_xcconfig_key_count "$file" "$key")
        if [[ "$count" != "1" ]]; then
            aub_fail "Version.xcconfig must contain exactly one $key assignment (found $count)."
            return 1
        fi
    done

    typeset -g AUB_MARKETING_VERSION="$(aub_xcconfig_value "$file" MARKETING_VERSION)"
    typeset -g AUB_BUILD_NUMBER="$(aub_xcconfig_value "$file" CURRENT_PROJECT_VERSION)"
    typeset -g AUB_RELEASE_SUFFIX="$(aub_xcconfig_value "$file" AUB_RELEASE_SUFFIX)"
    aub_validate_release_metadata "$AUB_MARKETING_VERSION" "$AUB_BUILD_NUMBER" "$AUB_RELEASE_SUFFIX"
}

aub_compute_next_release() {
    local next_minor=$1
    local make_final=$2
    local -a parts
    local major minor patch next_build

    parts=(${(s:.:)AUB_MARKETING_VERSION})
    major=$parts[1]
    minor=$parts[2]
    patch=$parts[3]

    if (( next_minor )); then
        (( minor += 1 ))
        patch=100
    else
        if (( AUB_BUILD_NUMBER < AUB_PUBLIC_BUILD_FLOOR )); then
            aub_fail "The first public candidate must use --next-minor (target 0.4.100)."
            return 1
        fi
        if (( patch >= 999 )); then
            aub_fail "Patch $patch is exhausted; use --next-minor."
            return 1
        fi
        (( patch += 1 ))
    fi

    if (( AUB_BUILD_NUMBER < AUB_PUBLIC_BUILD_FLOOR )); then
        next_build=$AUB_PUBLIC_BUILD_FLOOR
    else
        (( next_build = AUB_BUILD_NUMBER + 1 ))
    fi
    if (( next_build > AUB_MAX_BUILD_NUMBER )); then
        aub_fail "Build $AUB_BUILD_NUMBER is exhausted; choose a new Apple-compatible build scheme."
        return 1
    fi

    typeset -g AUB_TARGET_MARKETING_VERSION="$major.$minor.$patch"
    typeset -g AUB_TARGET_BUILD_NUMBER="$next_build"
    if (( make_final )); then
        typeset -g AUB_TARGET_RELEASE_SUFFIX=""
    else
        typeset -g AUB_TARGET_RELEASE_SUFFIX="$AUB_RELEASE_SUFFIX"
    fi
    aub_validate_release_metadata \
        "$AUB_TARGET_MARKETING_VERSION" \
        "$AUB_TARGET_BUILD_NUMBER" \
        "$AUB_TARGET_RELEASE_SUFFIX"
}

aub_join_release_version() {
    local version=$1
    local suffix=$2
    if [[ -n "$suffix" ]]; then
        print -r -- "$version-$suffix"
    else
        print -r -- "$version"
    fi
}

aub_json_get() {
    local file=$1
    local key=$2
    /usr/bin/plutil -extract "$key" raw -o - "$file" 2>/dev/null
}

aub_json_put_string() {
    local file=$1
    local key=$2
    local value=$3
    /usr/bin/plutil -insert "$key" -string "$value" "$file"
}

aub_json_put_integer() {
    local file=$1
    local key=$2
    local value=$3
    /usr/bin/plutil -insert "$key" -integer "$value" "$file"
}

aub_json_put_boolean() {
    local file=$1
    local key=$2
    local value=$3
    /usr/bin/plutil -insert "$key" -bool "$value" "$file"
}
