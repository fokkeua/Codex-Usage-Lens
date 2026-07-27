# Security policy

## Supported versions

Security fixes are provided for the latest release.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or include real Codex
data in a report.

Use GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Advisories**.
3. Select **Report a vulnerability**.

Include the affected version, impact, reproducible steps using synthetic data,
and any suggested mitigation. Remove credentials, prompts, account identifiers,
local paths, and unrelated logs.

If the private reporting button is not available, ask the repository owner to
enable private vulnerability reporting without disclosing vulnerability
details in a public issue.

Maintainers should acknowledge a complete report within seven days and provide
status updates until a fix or disposition is available. Timelines depend on
severity and reproducibility.

## Scope

Particularly relevant areas include:

- parsing untrusted JSON, JSONL, CSV, OTLP, or app-server responses;
- reads from local Codex session files;
- writes to application state and Codex OTel configuration;
- the authenticated loopback OTel receiver;
- remote pricing fetches and redirect handling;
- release archive construction, signing, and notarization.
