#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAX_TRACKED_FILE_BYTES=$((5 * 1024 * 1024))

fail() {
    print -u2 "error: $1"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || fail "required command is unavailable: $1"
}

for tool in git stat grep strings awk plutil zsh swift; do
    require_command "$tool"
done

cd "$PROJECT_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "run this audit from a Git repository"

[[ -n "$(git ls-files)" ]] || fail "the repository has no tracked files"

for required_file in \
    README.md LICENSE CHANGELOG.md CONTRIBUTING.md \
    CODE_OF_CONDUCT.md SECURITY.md SUPPORT.md Package.swift \
    docs/PRIVACY.md docs/RELEASING.md \
    Assets/CodexUsageLens-Promo.png \
    .github/workflows/ci.yml .github/workflows/release.yml; do
    git ls-files --error-unmatch "$required_file" >/dev/null 2>&1 \
        || fail "required public file is not tracked: $required_file"
done

unsafe_mode="$(
    git ls-files -s \
        | awk '$1 != "100644" && $1 != "100755" { print; exit }'
)"
[[ -z "$unsafe_mode" ]] \
    || fail "tracked symlink or unsupported file mode: $unsafe_mode"

git ls-files -z | while IFS= read -r -d '' tracked_file; do
    [[ -f "$tracked_file" && ! -L "$tracked_file" ]] \
        || fail "tracked path is not a regular file: $tracked_file"

    case "$tracked_file" in
        .build/*|.swiftpm/*|build/*|outputs/*|tmp/*|work/*|.claude/*|.codex/*)
            fail "local-only path is tracked: $tracked_file"
            ;;
        .DS_Store|*/.DS_Store|._*|*/._*|*.app/*|*.dSYM/*)
            fail "generated macOS path is tracked: $tracked_file"
            ;;
        .env|.env.*|*.cer|*.crt|*.key|*.mobileprovision|*.p12|*.pem)
            fail "credential or signing file is tracked: $tracked_file"
            ;;
        *.dmg|*.pkg|*.zip)
            fail "binary release artifact is tracked: $tracked_file"
            ;;
    esac

    size="$(stat -f%z "$tracked_file")"
    (( size <= MAX_TRACKED_FILE_BYTES )) \
        || fail "tracked file exceeds 5 MiB: $tracked_file ($size bytes)"
done

secret_patterns=(
    'sk-[A-Za-z0-9_-]{16,}'
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'AKIA[0-9A-Z]{16}'
    'ASIA[0-9A-Z]{16}'
    'AIza[0-9A-Za-z_-]{30,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY'
)

for pattern in "${secret_patterns[@]}"; do
    if git grep -I -n -E \
        -- "$pattern" \
        -- . ':(exclude)scripts/audit-repository.sh'; then
        fail "a high-confidence secret pattern was found"
    fi
done

identity_patterns=(
    '/Users/[^/[:space:]]+/'
    '/home/[^/[:space:]]+/'
    '(^|[^[:alnum:]._%+/@:-])[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
)

for pattern in "${identity_patterns[@]}"; do
    if git grep -I -n -E \
        -- "$pattern" \
        -- . \
        ':(exclude)scripts/audit-repository.sh' \
        ':(exclude)Packaging/Assets.xcassets/AppIcon.appiconset/Contents.json'; then
        fail "a personal identifier or absolute home path was found"
    fi
done

for screenshot in Assets/CodexUsageLens-Promo.png; do
    screenshot_metadata="$(strings "$screenshot")"
    for pattern in "${secret_patterns[@]}" "${identity_patterns[@]}"; do
        if print -r -- "$screenshot_metadata" | grep -E -q -- "$pattern"; then
            fail "secret or personal metadata was found in $screenshot"
        fi
    done
done

plutil -lint Packaging/Info.plist >/dev/null
plutil -convert json -o /dev/null Packaging/Assets.xcassets/Contents.json
plutil -convert json -o /dev/null \
    Packaging/Assets.xcassets/AppIcon.appiconset/Contents.json

app_version="$(
    plutil -extract CFBundleShortVersionString raw Packaging/Info.plist
)"
app_build="$(plutil -extract CFBundleVersion raw Packaging/Info.plist)"
grep -F "Current version: **$app_version (build $app_build)**." \
    README.md >/dev/null \
    || fail "README.md version does not match Packaging/Info.plist"

zsh -n scripts/*.sh
swift package dump-package >/dev/null

CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache" \
swift test --disable-sandbox

print "Repository audit passed."
