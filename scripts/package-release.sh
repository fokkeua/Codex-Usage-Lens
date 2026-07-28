#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/outputs"
SWIFTPM_BUILD_DIR="$PROJECT_DIR/.build"
MODULE_CACHE_DIR="$SWIFTPM_BUILD_DIR/ModuleCache"
APP_DIR="$BUILD_DIR/Codex Usage Lens.app"
APP_BINARY="$APP_DIR/Contents/MacOS/CodexUsageMenuBar"
APP_ZIP="$OUTPUT_DIR/CodexUsageLens-app-arm64.zip"
SOURCE_ZIP="$OUTPUT_DIR/CodexUsageLens-source.zip"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ALLOW_UNNOTARIZED_RELEASE="${ALLOW_UNNOTARIZED_RELEASE:-0}"

fail() {
    print -u2 "error: $1"
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || fail "required command is unavailable: $1"
}

ensure_real_directory() {
    local directory="$1"

    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" && ! -L "$directory" ]] \
            || fail "refusing unsafe non-directory or symlink: $directory"
    else
        mkdir "$directory"
    fi

    [[ -d "$directory" && ! -L "$directory" ]] \
        || fail "could not create a safe directory: $directory"
}

validate_directory_endpoint() {
    local directory="$1"
    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" && ! -L "$directory" ]] \
            || fail "refusing unsafe non-directory or symlink: $directory"
    fi
}

validate_publish_target() {
    local target="$1"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] \
            || fail "refusing unsafe archive target: $target"
    fi
}

validate_safe_tree() {
    local root="$1"
    local label="$2"
    local unsafe_entry
    local hardlinked_file

    # -P is explicit even though it is find's default: discovery must lstat a
    # symlink and must never walk through it to inspect or copy its target.
    if ! unsafe_entry="$(
        /usr/bin/find -P "$root" \( ! -type d ! -type f \) \
            -print -quit 2>&1
    )"; then
        fail "could not safely inspect $label: $unsafe_entry"
    fi
    [[ -z "$unsafe_entry" ]] \
        || fail "unsafe symlink or special entry in $label: $unsafe_entry"

    # A hard link can smuggle an otherwise external inode into the archive
    # while still reporting as a regular file.
    if ! hardlinked_file="$(
        /usr/bin/find -P "$root" -type f -links +1 -print -quit 2>&1
    )"; then
        fail "could not safely inspect $label: $hardlinked_file"
    fi
    [[ -z "$hardlinked_file" ]] \
        || fail "unsafe hard-linked file in $label: $hardlinked_file"
}

validate_archive_entry_types() {
    local archive="$1"
    local unsafe_entry

    if ! unsafe_entry="$(
        zipinfo -l "$archive" \
            | /usr/bin/awk \
                '$1 ~ /^[lpsbc]/ && !found { print; found = 1 }'
    )"; then
        fail "could not inspect staged source archive entry types"
    fi
    [[ -z "$unsafe_entry" ]] \
        || fail "unsafe entry type in staged source archive: $unsafe_entry"
}

preflight_signing_identity() {
    [[ -n "$CODE_SIGN_IDENTITY" && "$CODE_SIGN_IDENTITY" != "-" ]] \
        || return 0

    local identities
    if ! identities="$(security find-identity -v -p codesigning 2>/dev/null)"; then
        fail "could not inspect code-signing identities"
    fi

    local requested_upper="${(U)CODE_SIGN_IDENTITY}"
    local identity_line
    local identity_line_upper
    local matched_identity=""
    local matches=0
    while IFS= read -r identity_line; do
        identity_line_upper="${(U)identity_line}"
        if [[ "$identity_line_upper" == *"$requested_upper"* ]]; then
            matched_identity="$identity_line"
            (( matches += 1 ))
        fi
    done <<< "$identities"

    (( matches == 1 )) \
        || fail \
            "code-signing identity is unavailable or ambiguous: $CODE_SIGN_IDENTITY"

    if [[ "$ALLOW_UNNOTARIZED_RELEASE" != "1" \
        || -n "$NOTARY_PROFILE" ]]; then
        local matched_identity_upper="${(U)matched_identity}"
        [[ "$matched_identity_upper" == *"DEVELOPER ID APPLICATION:"* ]] \
            || fail \
                "distribution packaging requires a Developer ID Application identity"
    fi
}

[[ "$ALLOW_UNNOTARIZED_RELEASE" == "0" \
    || "$ALLOW_UNNOTARIZED_RELEASE" == "1" ]] \
    || fail "ALLOW_UNNOTARIZED_RELEASE must be 0 or 1"

HAS_DISTRIBUTION_IDENTITY=0
if [[ -n "$CODE_SIGN_IDENTITY" && "$CODE_SIGN_IDENTITY" != "-" ]]; then
    HAS_DISTRIBUTION_IDENTITY=1
fi

# All distribution gates run before mkdir, mktemp, SwiftPM, or canonical output
# mutation. A notary profile is never meaningful with an ad-hoc signature.
if [[ -n "$NOTARY_PROFILE" && "$HAS_DISTRIBUTION_IDENTITY" != "1" ]]; then
    fail "NOTARY_PROFILE requires a non-ad-hoc CODE_SIGN_IDENTITY"
fi
if [[ "$ALLOW_UNNOTARIZED_RELEASE" != "1" \
    && "$HAS_DISTRIBUTION_IDENTITY" != "1" ]]; then
    print -u2 "error: distribution packaging requires CODE_SIGN_IDENTITY."
    print -u2 "For local QA only, set ALLOW_UNNOTARIZED_RELEASE=1."
    exit 2
fi
if [[ "$ALLOW_UNNOTARIZED_RELEASE" != "1" && -z "$NOTARY_PROFILE" ]]; then
    print -u2 "error: set NOTARY_PROFILE to notarize the signed app."
    print -u2 \
        "For an explicitly local unnotarized package, set ALLOW_UNNOTARIZED_RELEASE=1."
    exit 2
fi

for tool in zsh security swift xcrun codesign ditto zip unzip zipinfo lipo find \
    mkdir mktemp; do
    require_command "$tool"
done
preflight_signing_identity
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool history \
        --keychain-profile "$NOTARY_PROFILE" \
        >/dev/null
fi

for directory in Sources Tests Packaging scripts samples docs .github; do
    [[ -d "$PROJECT_DIR/$directory" && ! -L "$PROJECT_DIR/$directory" ]] \
        || fail "source directory is missing or unsafe: $directory"
    validate_safe_tree "$PROJECT_DIR/$directory" "source tree $directory"
done
for file in \
    Package.swift README.md LICENSE CHANGELOG.md \
    CONTRIBUTING.md \
    CODE_OF_CONDUCT.md SECURITY.md SUPPORT.md .gitignore .gitattributes \
    Assets/CodexUsageLens-AppIcon.png Assets/CodexUsageLens-Promo.png; do
    [[ -f "$PROJECT_DIR/$file" && ! -L "$PROJECT_DIR/$file" ]] \
        || fail "source file is missing or unsafe: $file"
    validate_safe_tree "$PROJECT_DIR/$file" "source file $file"
done

validate_directory_endpoint "$SWIFTPM_BUILD_DIR"
validate_directory_endpoint "$MODULE_CACHE_DIR"
validate_directory_endpoint "$BUILD_DIR"
validate_directory_endpoint "$OUTPUT_DIR"
if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] \
        || fail "refusing unsafe app target: $APP_DIR"
fi
validate_publish_target "$APP_ZIP"
validate_publish_target "$SOURCE_ZIP"

# All directory and artifact endpoints were inspected before the first mkdir.
ensure_real_directory "$BUILD_DIR"
ensure_real_directory "$OUTPUT_DIR"

OUTPUT_STAGING_DIR=""
BUILD_STAGING_DIR=""
if ! OUTPUT_STAGING_DIR="$(
    mktemp -d "$OUTPUT_DIR/.CodexUsageLens-release.XXXXXX"
)"; then
    fail "could not create output staging"
fi
if ! BUILD_STAGING_DIR="$(
    mktemp -d "$BUILD_DIR/.CodexUsageLens-package.XXXXXX"
)"; then
    /bin/rm -rf "$OUTPUT_STAGING_DIR"
    fail "could not create build staging"
fi
SOURCE_STAGING_DIR="$OUTPUT_STAGING_DIR/source"
STAGED_APP_ZIP="$OUTPUT_STAGING_DIR/CodexUsageLens-app-arm64.zip"
STAGED_SOURCE_ZIP="$OUTPUT_STAGING_DIR/CodexUsageLens-source.zip"
NOTARY_SUBMISSION_ZIP="$OUTPUT_STAGING_DIR/notary-submission.zip"
PREVIOUS_APP="$BUILD_STAGING_DIR/previous-Codex Usage Lens.app"
FAILED_APP="$BUILD_STAGING_DIR/failed-Codex Usage Lens.app"
PREVIOUS_APP_ZIP="$OUTPUT_STAGING_DIR/previous-app.zip"
PREVIOUS_SOURCE_ZIP="$OUTPUT_STAGING_DIR/previous-source.zip"
FAILED_APP_ZIP="$OUTPUT_STAGING_DIR/failed-app.zip"
FAILED_SOURCE_ZIP="$OUTPUT_STAGING_DIR/failed-source.zip"

APP_HAD_PREVIOUS=0
APP_TRANSACTION_STARTED=0
ZIP_TRANSACTION_STARTED=0
APP_ZIP_HAD_PREVIOUS=0
SOURCE_ZIP_HAD_PREVIOUS=0
APP_ZIP_PUBLISHED=0
SOURCE_ZIP_PUBLISHED=0
PACKAGE_COMPLETE=0

rollback_release() {
    local rollback_failed=0

    if (( ZIP_TRANSACTION_STARTED == 1 )); then
        if (( APP_ZIP_PUBLISHED == 1 )); then
            if [[ -f "$APP_ZIP" && ! -L "$APP_ZIP" ]]; then
                /bin/mv "$APP_ZIP" "$FAILED_APP_ZIP" || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
        if (( SOURCE_ZIP_PUBLISHED == 1 )); then
            if [[ -f "$SOURCE_ZIP" && ! -L "$SOURCE_ZIP" ]]; then
                /bin/mv "$SOURCE_ZIP" "$FAILED_SOURCE_ZIP" \
                    || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
        if (( APP_ZIP_HAD_PREVIOUS == 1 )); then
            if [[ ! -e "$APP_ZIP" && ! -L "$APP_ZIP" \
                && -f "$PREVIOUS_APP_ZIP" \
                && ! -L "$PREVIOUS_APP_ZIP" ]]; then
                /bin/mv "$PREVIOUS_APP_ZIP" "$APP_ZIP" \
                    || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
        if (( SOURCE_ZIP_HAD_PREVIOUS == 1 )); then
            if [[ ! -e "$SOURCE_ZIP" && ! -L "$SOURCE_ZIP" \
                && -f "$PREVIOUS_SOURCE_ZIP" \
                && ! -L "$PREVIOUS_SOURCE_ZIP" ]]; then
                /bin/mv "$PREVIOUS_SOURCE_ZIP" "$SOURCE_ZIP" \
                    || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
    fi

    if (( APP_TRANSACTION_STARTED == 1 )); then
        if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
            if [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]; then
                /bin/mv "$APP_DIR" "$FAILED_APP" || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
        if (( APP_HAD_PREVIOUS == 1 )); then
            if [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" \
                && -d "$PREVIOUS_APP" && ! -L "$PREVIOUS_APP" ]]; then
                /bin/mv "$PREVIOUS_APP" "$APP_DIR" || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
    fi

    return "$rollback_failed"
}

cleanup() {
    local exit_status=$?
    local cleanup_ok=1
    set +e
    trap - EXIT HUP INT TERM

    if (( PACKAGE_COMPLETE == 0 )); then
        rollback_release
        [[ $? == 0 ]] || cleanup_ok=0
    fi

    if (( cleanup_ok == 1 )); then
        if [[ -n "${OUTPUT_STAGING_DIR:-}" \
            && -d "$OUTPUT_STAGING_DIR" \
            && ! -L "$OUTPUT_STAGING_DIR" ]]; then
            /bin/rm -rf "$OUTPUT_STAGING_DIR" || cleanup_ok=0
        fi
        if [[ -n "${BUILD_STAGING_DIR:-}" \
            && -d "$BUILD_STAGING_DIR" \
            && ! -L "$BUILD_STAGING_DIR" ]]; then
            /bin/rm -rf "$BUILD_STAGING_DIR" || cleanup_ok=0
        fi
    fi

    if (( cleanup_ok == 0 )); then
        print -u2 "error: release cleanup or rollback was incomplete."
        print -u2 "Output staging, if present: $OUTPUT_STAGING_DIR"
        print -u2 "Build staging, if present: $BUILD_STAGING_DIR"
        (( exit_status == 0 )) && exit_status=1
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Preserve the prior app across every later failure, including notarization.
# Keep the canonical app in place while build-app performs its own staged swap.
if [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]; then
    ditto --norsrc "$APP_DIR" "$PREVIOUS_APP"
    APP_HAD_PREVIOUS=1
fi
APP_TRANSACTION_STARTED=1

if [[ "$HAS_DISTRIBUTION_IDENTITY" == "1" ]]; then
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        zsh "$PROJECT_DIR/scripts/build-app.sh" release >/dev/null
else
    CODE_SIGN_IDENTITY="-" \
        zsh "$PROJECT_DIR/scripts/build-app.sh" release >/dev/null
fi

[[ -f "$APP_BINARY" && ! -L "$APP_BINARY" ]] \
    || fail "built app binary is missing or unsafe: $APP_BINARY"
APP_ARCHITECTURES="$(lipo -archs "$APP_BINARY")"
[[ "$APP_ARCHITECTURES" == "arm64" ]] \
    || fail "arm64 archive requires a thin arm64 binary; got: $APP_ARCHITECTURES"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --keepParent --norsrc "$APP_DIR" \
        "$NOTARY_SUBMISSION_ZIP"
    unzip -tq "$NOTARY_SUBMISSION_ZIP" >/dev/null
    xcrun notarytool submit "$NOTARY_SUBMISSION_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

ditto -c -k --keepParent --norsrc "$APP_DIR" "$STAGED_APP_ZIP"

mkdir "$SOURCE_STAGING_DIR"
for directory in Sources Tests Packaging scripts samples docs .github; do
    ditto --norsrc "$PROJECT_DIR/$directory" \
        "$SOURCE_STAGING_DIR/$directory"
done
for file in \
    Package.swift README.md LICENSE CHANGELOG.md \
    CONTRIBUTING.md \
    CODE_OF_CONDUCT.md SECURITY.md SUPPORT.md .gitignore .gitattributes; do
    ditto --norsrc "$PROJECT_DIR/$file" "$SOURCE_STAGING_DIR/$file"
done
mkdir "$SOURCE_STAGING_DIR/Assets"
ditto --norsrc "$PROJECT_DIR/Assets/CodexUsageLens-AppIcon.png" \
    "$SOURCE_STAGING_DIR/Assets/CodexUsageLens-AppIcon.png"
ditto --norsrc "$PROJECT_DIR/Assets/CodexUsageLens-Promo.png" \
    "$SOURCE_STAGING_DIR/Assets/CodexUsageLens-Promo.png"

# Revalidate the materialized staging tree immediately before zip. `-y`
# additionally prevents zip from dereferencing a symlink introduced during the
# bounded race window between this lstat walk and archive traversal.
validate_safe_tree "$SOURCE_STAGING_DIR" "staged source tree"
(
    cd "$SOURCE_STAGING_DIR"
    zip -q -r -y -X "$STAGED_SOURCE_ZIP" .
)
validate_safe_tree "$SOURCE_STAGING_DIR" "staged source tree after archive"
validate_archive_entry_types "$STAGED_SOURCE_ZIP"

unzip -tq "$STAGED_APP_ZIP" >/dev/null
unzip -tq "$STAGED_SOURCE_ZIP" >/dev/null

# Both staged ZIPs are now complete and verified. Each final move is a
# same-filesystem rename; the EXIT trap restores the complete prior pair if a
# later rename fails.
ZIP_TRANSACTION_STARTED=1
if [[ -f "$APP_ZIP" && ! -L "$APP_ZIP" ]]; then
    /bin/mv "$APP_ZIP" "$PREVIOUS_APP_ZIP"
    APP_ZIP_HAD_PREVIOUS=1
fi
if [[ -f "$SOURCE_ZIP" && ! -L "$SOURCE_ZIP" ]]; then
    /bin/mv "$SOURCE_ZIP" "$PREVIOUS_SOURCE_ZIP"
    SOURCE_ZIP_HAD_PREVIOUS=1
fi
/bin/mv "$STAGED_APP_ZIP" "$APP_ZIP"
APP_ZIP_PUBLISHED=1
/bin/mv "$STAGED_SOURCE_ZIP" "$SOURCE_ZIP"
SOURCE_ZIP_PUBLISHED=1
PACKAGE_COMPLETE=1

echo "$APP_ZIP"
echo "$SOURCE_ZIP"
