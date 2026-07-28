# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The menu, dashboard, and settings now follow the macOS light or dark
  appearance automatically.
- The About window now includes a product overview, privacy note, dynamic
  version information, and links to GitHub, documentation, issues, and license.

### Changed

- The status-panel opens to the right of its menu-bar icon when screen space
  allows, while remaining clamped inside the active display.
- Dashboard and Settings now share the menu's system typography, SF Symbols,
  cyan accent, material surfaces, compact spacing, and adaptive appearance.

### Fixed

- The menu now prefers the active Codex rate-limit plan over the generic
  ChatGPT account label and displays the Pro tiers as Pro 5x or Pro 20x.

## [1.3.0] - 2026-07-27

### Added

- A redesigned Codex-style menu panel with weekly rate-limit pacing,
  reset-credit availability, live account identity and plan, 30-day cost and
  token metrics, a compact chart, credit balance, service status, and native
  action rows.
- Stable Codex app-server integration for `account/read`,
  `account/rateLimits/read`, and confirmed reset-credit consumption.
- A browser-based Codex account login flow with an explicit active-account
  switch warning.
- Live OpenAI status-page summaries in the menu.
- A native macOS Login Item toggle in Settings for launching Codex Usage Lens
  automatically after sign-in, including approval and error states.
- Open-source project documentation and GitHub community files.
- English, Ukrainian, and Russian README screenshots based on demo data.
- A complete Ukrainian README.
- Repository privacy and release audits.
- GitHub Actions validation for supported macOS builds.

### Fixed

- All dashboard status text now refreshes immediately after changing the
  application language.

## [1.2.0] - 2026-07-27

### Added

- Official Codex app-server usage synchronization.
- Authenticated local OTel receiver for live response detail.
- Experimental historical backfill from local Codex session files.
- API-equivalent pricing with editable matching rules.
- JSON, JSONL/NDJSON, OTLP JSON, and CSV imports.
- Local durable state with single-writer coordination.
- Release packaging with signing, notarization, and archive safety checks.
- Security hardening for bounded input, file handling, redirects, and
  persistence races.
