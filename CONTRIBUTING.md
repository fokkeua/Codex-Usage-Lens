# Contributing

Thank you for helping improve Codex Usage Lens.

## Before you start

- Search existing issues before opening a new one.
- Use an issue for a substantial behavioral change so the approach can be
  discussed before implementation.
- Do not include real Codex session data, prompts, credentials, account
  identifiers, or local state in issues, fixtures, screenshots, or commits.
- Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).

## Development setup

Requirements:

- macOS 14 or newer;
- Xcode Command Line Tools or Xcode with Swift 6.

Clone the repository and run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox
```

Build and launch the menu bar app with:

```bash
zsh scripts/run-app.sh
```

Run the repository release audit before submitting:

```bash
zsh scripts/audit-repository.sh
```

## Pull requests

Keep pull requests focused. Include:

- a clear explanation of the problem and the chosen behavior;
- tests for behavior changes and input-boundary changes;
- updated documentation when data handling, settings, pricing, or release
  behavior changes;
- confirmation that the repository audit passes.

Avoid drive-by formatting of unrelated files. The codebase contains
concurrency, file-system, parsing, and persistence hardening where apparently
cosmetic changes can make review harder.

## Test data

Use synthetic data only. The files in `samples/` show the expected shape. Never
commit files copied from `~/.codex`, `~/Library/Application Support`, or a real
OTel export.

## Commit and release conventions

Write imperative, scoped commit messages. User-visible changes belong in
`CHANGELOG.md`. Releases are tagged as `vMAJOR.MINOR.PATCH`; the app version and
build are stored in `Packaging/Info.plist`.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
