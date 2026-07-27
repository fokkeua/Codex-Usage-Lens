# Privacy

Codex Usage Lens is designed as a local-first application. This document
describes what it reads, stores, sends, and deliberately avoids.

## Data the app reads

- official usage totals from the locally launched Codex app-server;
- model/settings metadata and token counts from local Codex session JSONL files;
- authenticated OTel usage events delivered to the loopback receiver;
- user-selected import files;
- public pricing pages on `developers.openai.com`.

The local session parser does not deserialize prompt text, assistant text,
reasoning text, tool payloads, or credentials. The app does not read Codex
`auth.json`.

## Data the app stores

The app stores its state under:

```text
~/Library/Application Support/CodexUsageMenuBar/
```

The directory is restricted to mode `0700`; state and capability files use
mode `0600`. Stored records contain token usage, timestamps, model and service
tier metadata, pricing configuration, and synchronization metadata. Raw thread
IDs and source event IDs are not persisted.

Corrupt state may be quarantined beside the main state file for diagnosis. It
is still local and protected by the same application directory permissions.

## Network activity

The app communicates with:

- the local Codex app-server process;
- an authenticated OTel HTTP listener bound to `127.0.0.1`;
- official OpenAI model pricing pages over HTTPS.

Codex Usage Lens does not include analytics, advertising, crash reporting, or
its own remote telemetry service.

## OTel configuration

With explicit confirmation, the app can append an `[otel]` section to the local
Codex configuration. It sets `log_user_prompt = false`, generates a private
capability, and refuses to overwrite an existing OTel configuration.

## Imports and issue reports

Imported files remain local. Contributors and users should never attach real
session files, application state, prompts, credentials, account identifiers,
or unredacted screenshots to GitHub issues or pull requests. Use the synthetic
fixtures in `samples/` when reproducing behavior.

## Removing local data

Quit every running instance of Codex Usage Lens before removing its application
support directory. Deleting that directory removes saved usage history,
pricing configuration, synchronization state, and the OTel capability. Review
the Codex configuration separately if OTel was enabled.
