# Design QA — Codex Usage Lens menu

## Comparison target

- Source visual truth: `design-qa-evidence/reference.jpg`
- Rendered implementation: `design-qa-evidence/implementation-final.png`
- Full-view comparison: `design-qa-evidence/comparison-final.png`
- Focused header/weekly comparison: `design-qa-evidence/comparison-top-final.png`
- Focused action-list comparison: `design-qa-evidence/comparison-actions-final.png`
- State: light appearance, English localization, live account data loaded, Plan Usage and Cost collapsed.
- Native viewport: 360 pt wide. The QA preview window capture was 360 × 891 px; 31 px of window title chrome was removed to produce a 360 × 860 px content capture.
- Source pixels: 571 × 1280. The visible panel was cropped to 499 × 1209 px and normalized to 360 × 872 px.
- Density normalization: both content regions were compared at 360 captured pixels wide. The 12 px height difference was preserved and padded rather than stretched.

## Findings

- No actionable P0, P1, or P2 differences remain.
- Typography: both use the macOS system family with closely matched optical weights, sizes, line heights, truncation, and hierarchy. The implementation preserves readable small text and does not wrap the compact rows.
- Spacing and layout rhythm: section order, 16 pt side insets, divider cadence, metric grid, chart region, disclosure rows, action rows, and total panel height closely match the source. The implementation is 12 normalized pixels shorter, which is acceptable and does not change density or hide controls.
- Colors and tokens: the cyan accent was adjusted to match the source’s weekly bar and histogram. The implementation uses native light material rather than reproducing the dim gray cast introduced by the JPEG capture.
- Image and icon fidelity: the source contains no product imagery that needs a raster asset. The chart is a real data visualization and icons use native SF Symbols; no emoji, placeholder art, handcrafted SVG, or CSS-style drawing substitutes are present.
- Copy and content: the visible information architecture matches the source. Email, plan, limits, credits, prices, tokens, chart bars, status, and timestamps intentionally use live account data rather than the sample values in the reference. “Codex Usage Lens” is retained in About because it is the existing product name.

## Interaction verification

- Plan Usage disclosure opens and shows the live limit window and reset time.
- Cost disclosure opens and shows Today, 7-day, and 30-day estimates.
- Add Account opens a warning that Codex keeps one active login; the OAuth action was not completed during QA.
- Limit Reset Credits opens a consumption confirmation; no credit was consumed during QA.
- Usage Dashboard and Settings both opened their existing native windows.
- OpenAI system status loaded from the public status endpoint.

## Comparison history

1. Preliminary native capture found missing rate-limit metadata, missing status data, mixed localization, dark appearance, and an incorrectly oriented expected-usage marker.
   - Fixes: added stable `account/read` and `account/rateLimits/read` decoding, corrected snake-case status decoding, completed all six localization catalogs, matched the light source appearance, and placed the red marker on expected remaining usage.
   - Post-fix evidence: `comparison-final.png` and `comparison-top-final.png`.
2. Focused color review found the first implementation accent too green.
   - Fix: introduced a menu-specific cyan token and applied it to the weekly bar, chart, and credits progress.
   - Post-fix evidence: `comparison-final.png`.
3. Final full-view and focused-region review found no actionable P0/P1/P2 differences.

## Open Questions

- None.

## Implementation Checklist

- [x] Source and implementation normalized to the same width and state.
- [x] Fonts and typography checked.
- [x] Spacing, frame size, dividers, and vertical rhythm checked.
- [x] Colors and semantic accents checked.
- [x] Chart and SF Symbol fidelity checked.
- [x] Dynamic copy and content checked.
- [x] Core disclosures, confirmations, dashboard, settings, and status loading checked.

## Follow-up Polish

- P3: the source screenshot is visibly dimmer and contains a redacted header. The implementation keeps native macOS material and shows the active account email, as requested.
- P3: the reference says “About CodexBar”; the implementation correctly preserves the existing “Codex Usage Lens” product name.

## Rounded status-panel follow-up

- Source visual truth: `design-qa-evidence/corner-reference.png`
- Rendered implementation: `design-qa-evidence/corner-implementation.png`
- Same-scale top comparison: `design-qa-evidence/corner-comparison.png`
- The source is a 364 × 144 px crop. The implementation was captured at its native 360 px width and cropped to the same 144 px height; neither side was stretched.
- The system `NSPopover` arrow that distorted the icon-side corner was replaced by a nonactivating native panel with a continuous 16 pt corner radius and a 6 pt gap below the status item.
- Both top corners now render as a clean rounded rectangle. No P0, P1, or P2 visual differences remain for the requested corner change.
- Interaction verification: Plan Usage still expands and resizes the panel from the same top anchor; Escape closes it.

## Dashboard and Settings visual-system follow-up

### Comparison target

- Shared style source: `design-qa-evidence/style-reference-menu.png`
- Dashboard implementation: `design-qa-evidence/dashboard-after-1.png`
- Settings implementation: `design-qa-evidence/settings-after-2.png`
- Same-input Dashboard comparison: `design-qa-evidence/style-comparison-dashboard.png`
- Same-input Settings comparison: `design-qa-evidence/style-comparison-settings.png`
- Dark appearance comparison: `design-qa-evidence/style-comparison-dark.png`
- Additional states: `design-qa-evidence/dashboard-lower-dark-after.png`,
  `design-qa-evidence/settings-pricing-after.png`, and
  `design-qa-evidence/settings-about-after.png`.
- State: the shared source uses light appearance, Ukrainian localization, and a
  redacted preview account. Dashboard and Settings were checked in light and
  dark appearances with English localization and local application data.
- Captured pixels: source menu 360 × 859; Dashboard 900 × 682; Settings
  620 × 492. Comparisons preserve native sizes and pad the shorter view rather
  than stretching it.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Typography: the first Dashboard pass used an oversized rounded display face,
  while Settings relied on the visually unrelated native tab treatment. Both
  now use a shared macOS system-font scale with semibold section headings,
  compact row labels, secondary captions, and tab labels that match the menu.
- Spacing and surfaces: Dashboard and Settings now share 20 pt window padding,
  16 pt section rhythm, 12 pt continuous panel corners, subtle single-stroke
  borders, and regular material that follows the system appearance.
- Colors: the menu cyan is a single shared token for controls, headings,
  progress, and navigation. Orange remains reserved for warnings, while
  Dashboard chart colors remain semantic because they identify models.
- Image and icon fidelity: all interface icons are real SF Symbols. The earlier
  pastel icon tiles and the decorative gradient About mark were removed; there
  are no emoji, placeholder graphics, handcrafted SVG substitutes, or synthetic
  raster assets.
- Copy and content: all existing Dashboard metrics, charts, period choices, data
  source explanations, Settings controls, pricing fields, links, warnings, and
  confirmation flows were preserved.

### Interaction verification

- Dashboard opened from the menu, retained its 7/14/30/90-day selector, scrolled
  through the lower chart and detail panels, and rendered correctly in light and
  dark appearances.
- Settings opened from the menu and all three visible SF Symbol tabs — Data,
  Pricing, and About — were inspected.
- Pricing controls, status text, model cards, source link, and reset action
  remain present. About retains its documentation links and version information.
- Destructive clear, reset, and remove actions were not confirmed during QA.

### Implementation checklist

- [x] Shared fonts and hierarchy checked.
- [x] Shared spacing, panel shape, borders, and material checked.
- [x] Accent and semantic colors checked.
- [x] SF Symbol usage and removal of decorative fake imagery checked.
- [x] Copy, data states, and existing functions checked.
- [x] Light and dark appearances checked.
- [x] Full views and focused Dashboard/Settings comparisons checked together
  with the source menu.

## About window information follow-up

### Comparison target

- Source visual truth:
  `design-qa-evidence/about-source-crop.png`
- Final implementation:
  `design-qa-evidence/about-window-dark.png`
- Same-input source and implementation comparison:
  `design-qa-evidence/about-comparison-dark.png`
- Light and dark appearance comparison:
  `design-qa-evidence/about-comparison-themes.png`
- Source pixels: the supplied 792 × 564 screenshot was cropped to its
  568 × 338 window and proportionally normalized to 520 × 309.
- Implementation pixels and native window width: 520 × 631 in both
  appearances. The source was padded in the combined comparison rather than
  stretched vertically.
- State: Ukrainian localization, version 1.3 build 7, no account or usage data
  displayed.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Typography: the source icon/title/version hierarchy is preserved with the
  macOS system family. The implementation deliberately uses the shared
  24 pt semibold app-title token so the expanded content matches the menu,
  Dashboard, and Settings.
- Spacing and layout: the compact centered identity block remains at the top.
  The taller window is intentional and contains one overview panel, a single
  four-row link group, and an independent-project note with consistent
  20/16 pt rhythm and 12 pt continuous corners.
- Colors and tokens: the window follows system light/dark appearance and uses
  the same cyan accent, material surface, subtle borders, and semantic
  secondary text as the rest of the app.
- Image and icon fidelity: the real packaged application icon is used. All
  navigation and privacy marks are native SF Symbols; no generated artwork,
  placeholder graphics, emoji, gradients, handcrafted SVG, or code-drawn
  substitutes were introduced.
- Copy and content: the dynamic version/build, local-first description,
  on-device privacy note, GitHub, documentation, issue, and MIT license links,
  plus the independent-project disclosure are all visible and localized.
- Accessibility and interaction: Computer Use exposed all four destinations as
  semantic links with their full HTTPS targets. Window close/minimize controls
  remain native, and the Dock stays visible while the About window is open.

### Comparison history

1. The first implementation preserved the requested hierarchy and added all
   requested information, but the independent-project disclosure used a
   tertiary color that was too faint in light appearance.
   - Fix: promoted the disclosure to the shared secondary text color.
   - Post-fix evidence: `about-comparison-themes.png`.
2. The final combined source/implementation review found no actionable
   P0/P1/P2 mismatch. The increased height is required for the requested
   content and does not dilute the original identity hierarchy.

### Implementation checklist

- [x] Real app icon, system font hierarchy, and dynamic version checked.
- [x] Link labels, subtitles, SF Symbols, and HTTPS destinations checked.
- [x] Description, privacy note, and independent-project disclosure checked.
- [x] Native close/minimize behavior and activation policy checked.
- [x] Light and dark appearances checked.
- [x] Source and implementation inspected in one combined comparison.

final result: passed
