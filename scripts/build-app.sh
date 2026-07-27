#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${1:-release}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Codex Usage Lens.app"
SWIFTPM_BUILD_DIR="$PROJECT_DIR/.build"
MODULE_CACHE_DIR="$SWIFTPM_BUILD_DIR/ModuleCache"
ASSET_CATALOG="$PROJECT_DIR/Packaging/Assets.xcassets"
INFO_PLIST="$PROJECT_DIR/Packaging/Info.plist"

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

preflight_signing_identity() {
    [[ "$CODE_SIGN_IDENTITY" != "-" ]] || return 0

    local identities
    if ! identities="$(security find-identity -v -p codesigning 2>/dev/null)"; then
        fail "could not inspect code-signing identities"
    fi

    local requested_upper="${(U)CODE_SIGN_IDENTITY}"
    local identity_line
    local identity_line_upper
    local matches=0
    while IFS= read -r identity_line; do
        identity_line_upper="${(U)identity_line}"
        if [[ "$identity_line_upper" == *"$requested_upper"* ]]; then
            (( matches += 1 ))
        fi
    done <<< "$identities"

    (( matches == 1 )) \
        || fail \
            "code-signing identity is unavailable or ambiguous: $CODE_SIGN_IDENTITY"
}

[[ "$BUILD_CONFIGURATION" == "debug" || "$BUILD_CONFIGURATION" == "release" ]] \
    || fail "build configuration must be debug or release"
[[ -d "$ASSET_CATALOG" && ! -L "$ASSET_CATALOG" ]] \
    || fail "asset catalog is missing or unsafe: $ASSET_CATALOG"
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] \
    || fail "Info.plist is missing or unsafe: $INFO_PLIST"

for tool in swift xcrun codesign security cp chmod mkdir mktemp; do
    require_command "$tool"
done
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    require_command strip
fi

# Signing is checked before SwiftPM, build/, or the published app can change.
preflight_signing_identity
validate_directory_endpoint "$SWIFTPM_BUILD_DIR"
validate_directory_endpoint "$MODULE_CACHE_DIR"
validate_directory_endpoint "$BUILD_DIR"
if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] \
        || fail "refusing unsafe app target: $APP_DIR"
fi

# Every endpoint was inspected before the first directory creation.
ensure_real_directory "$SWIFTPM_BUILD_DIR"
ensure_real_directory "$MODULE_CACHE_DIR"
ensure_real_directory "$BUILD_DIR"

cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
BIN_DIR="$(swift build --disable-sandbox -c "$BUILD_CONFIGURATION" --show-bin-path)"
swift build --disable-sandbox -c "$BUILD_CONFIGURATION"

STAGING_DIR="$(mktemp -d "$BUILD_DIR/.CodexUsageLens-build.XXXXXX")"
STAGED_APP="$STAGING_DIR/Codex Usage Lens.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
STAGED_ASSET_INFO="$STAGING_DIR/AssetCatalog.plist"
PREVIOUS_APP="$STAGING_DIR/previous-Codex Usage Lens.app"
PUBLISH_STARTED=0
PUBLISH_COMPLETE=0
HAD_PREVIOUS_APP=0

cleanup() {
    local exit_status=$?
    local cleanup_ok=1
    set +e
    trap - EXIT HUP INT TERM

    if (( PUBLISH_STARTED == 1 && PUBLISH_COMPLETE == 0 \
        && HAD_PREVIOUS_APP == 1 )); then
        if [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" \
            && -d "$PREVIOUS_APP" && ! -L "$PREVIOUS_APP" ]]; then
            /bin/mv "$PREVIOUS_APP" "$APP_DIR" || cleanup_ok=0
        else
            cleanup_ok=0
        fi
    fi

    if (( cleanup_ok == 1 )); then
        if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" \
            && ! -L "$STAGING_DIR" ]]; then
            /bin/rm -rf "$STAGING_DIR" || cleanup_ok=0
        fi
    fi

    if (( cleanup_ok == 0 )); then
        print -u2 \
            "error: app cleanup or rollback was incomplete; staging: $STAGING_DIR"
        (( exit_status == 0 )) && exit_status=1
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
cp "$BIN_DIR/CodexUsageMenuBar" "$STAGED_MACOS/CodexUsageMenuBar"
RESOURCE_BUNDLE="$BIN_DIR/CodexUsageMenuBar_CodexUsageMenuBar.bundle"
[[ -d "$RESOURCE_BUNDLE" && ! -L "$RESOURCE_BUNDLE" ]] \
    || fail "localized resource bundle is missing or unsafe: $RESOURCE_BUNDLE"
cp -R "$RESOURCE_BUNDLE" "$STAGED_RESOURCES/"
for language_code in en fr es de ru uk; do
    LOCALIZATION_DIR="$RESOURCE_BUNDLE/$language_code.lproj"
    [[ -d "$LOCALIZATION_DIR" && ! -L "$LOCALIZATION_DIR" ]] \
        || fail "localization is missing or unsafe: $LOCALIZATION_DIR"
    cp -R "$LOCALIZATION_DIR" "$STAGED_RESOURCES/"
done
cp "$INFO_PLIST" "$STAGED_CONTENTS/Info.plist"
xcrun actool "$ASSET_CATALOG" \
    --compile "$STAGED_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$STAGED_ASSET_INFO" \
    --warnings \
    --notices
chmod +x "$STAGED_MACOS/CodexUsageMenuBar"
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    strip -x "$STAGED_MACOS/CodexUsageMenuBar"
fi

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$STAGED_APP"
    print -u2 "warning: ad-hoc signature is suitable only for local QA"
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$CODE_SIGN_IDENTITY" \
        "$STAGED_APP"
fi
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# Both directories live below build/, so each publish move is a same-filesystem
# rename. If the second move fails, the EXIT trap restores the prior app.
PUBLISH_STARTED=1
if [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]; then
    /bin/mv "$APP_DIR" "$PREVIOUS_APP"
    HAD_PREVIOUS_APP=1
fi
/bin/mv "$STAGED_APP" "$APP_DIR"
PUBLISH_COMPLETE=1

echo "$APP_DIR"
