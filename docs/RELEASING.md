# Releasing

This checklist covers a source release and an optional signed macOS binary.

## 1. Prepare the version

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in
   `Packaging/Info.plist`.
2. Update the version shown in `README.md`.
3. Move relevant entries from `CHANGELOG.md` into a dated release section.

## 2. Audit the source tree

Run:

```bash
zsh scripts/audit-repository.sh
```

Review the complete tracked-file list:

```bash
git ls-files
```

The audit rejects common secret formats, personal home paths, email addresses,
unsafe file types, oversized tracked files, and known local-only paths. It also
runs syntax checks and the complete Swift test suite.

Because automated secret detection is heuristic, manually review `git diff
--cached` before the first public push and before every release.

## 3. Build an ad-hoc Apple Silicon release locally

```bash
ALLOW_UNNOTARIZED_RELEASE=1 zsh scripts/package-release.sh
```

This creates an ad-hoc signed Apple Silicon app archive and a source archive:

```text
outputs/CodexUsageLens-app-arm64.zip
outputs/CodexUsageLens-source.zip
```

These files are ignored by Git. The app archive is suitable for a GitHub
Release, but it is not notarized. Users must Control-click the app and choose
**Open**, or allow it under **System Settings → Privacy & Security**.

## 4. Optional signed and notarized distribution

Create a keychain profile for Apple's notary service outside the repository,
then run:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="codex-usage-lens" \
zsh scripts/package-release.sh
```

The script requires a Developer ID Application identity, submits the app for
notarization, staples the ticket, verifies the signature, and atomically
publishes the app and source ZIP files under `outputs/`.

Never commit certificate files, App Store Connect credentials, keychain data,
notary credentials, or built archives.

## 5. Publish an ad-hoc GitHub Release

1. Confirm the repository is public and the default branch is protected.
2. Enable private vulnerability reporting under repository security settings.
3. Require the GitHub Actions `CI` check for pull requests.
4. Commit the release version and ensure the repository audit passes.
5. Tag the audited commit as `vMAJOR.MINOR.PATCH`. A two-component app version
   gets a `.0` patch component, so app version `1.3` uses tag `v1.3.0`.
6. Push the tag:

   ```bash
   git tag v1.3.0
   git push origin v1.3.0
   ```

7. The `Release` workflow runs on an Apple Silicon `macos-15` runner, verifies
   the tag and architecture, runs the repository audit, creates the ad-hoc
   archives and `SHA256SUMS`, and publishes them to GitHub Releases.
8. Install and launch the downloaded artifact on a clean supported Apple
   Silicon Mac.

This ad-hoc workflow uses only the built-in `GITHUB_TOKEN`. It does not require
an Apple Developer account, certificate, notarization profile, or repository
secrets. GitHub source archives remain the canonical source artifacts; the
generated source ZIP is an additional verified convenience archive.

If a signed and notarized release is published manually, do not mix it with an
ad-hoc artifact under the same version tag.
