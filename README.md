# Usage

A native macOS menu-bar app for monitoring AI subscription usage and API billing. Built with SwiftUI and AppKit; no third-party dependencies.

Requires **macOS 14+** and **Swift 6 / Xcode 16+** to build.

The static website and Cloudflare Pages deployment instructions are documented
in [`docs/website.md`](docs/website.md).

## Build and run

```sh
swift test
zsh scripts/build-app.sh
open dist/Usage.app
```

Run the app bundle rather than `swift run` so macOS notifications work. The build script signs the app ad hoc by default. To use a stable signing identity for Keychain access:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh scripts/build-app.sh
```

Distribution to other Macs also requires hardened runtime and notarization. Open `Package.swift` in Xcode to edit or debug the package.

## Connect accounts

Open **Accounts** from the menu-bar icon, select a provider, and follow the sign-in or verification prompts. Multiple accounts per provider are supported.

| Provider | Connection | Reading |
| --- | --- | --- |
| Claude subscription | Claude Code CLI sign-in, session import, or OAuth token | Subscription usage |
| OpenAI subscription | ChatGPT sign-in through the official Codex CLI | Reported ChatGPT/Codex quotas |
| Kimi subscription | Global Kimi browser sign-in or subscription API key | Kimi Code quotas |
| OpenCode | OpenCode Go workspace API key | Go usage |
| GitHub Copilot | GitHub device sign-in | Available Copilot quotas |
| Anthropic API | Claude Console organization Admin API key with analytics access | Organization month-to-date cost before credits |
| OpenAI API | Organization Admin API key with costs-read access | Organization month-to-date spend |
| Moonshot API | Global Open Platform API key | Available balance |

For Claude and OpenAI subscription sign-in, install the respective official CLI first. Claude Code sign-in affects your normal CLI session; OpenAI uses a separate Codex session for each Usage account. OpenCode requires a key with Go access. API billing accounts are separate from subscription accounts and do not show quota percentages.

Some provider endpoints are undocumented or evolving, and integrations are not guaranteed or live-verified with user credentials. GitHub sign-in may succeed even when its quota endpoint rejects access. Kimi browser sign-in uses a public client configuration whose third-party acceptance is not guaranteed; a subscription API key is an alternative. Review [OpenAI's authentication guidance](https://developers.openai.com/codex/app-server/#auth-endpoints) before commercial distribution.

## Usage and privacy

- Click the menu-bar icon to view usage; open **Accounts** to add, edit, refresh, or remove accounts.
- Healthy accounts refresh every 60 seconds while the Mac is awake. Failed readings retain the last successful result and are marked stale.
- With macOS notification permission, subscription usage alerts trigger at 70% and 100%. Manage notification delivery in System Settings.
- Credentials are stored in macOS Keychain; account metadata is stored in `~/Library/Application Support/Usage/accounts.json`. Usage snapshots are memory-only. Codex manages its own isolated credentials.
- Usage makes direct provider requests without telemetry or an intermediary backend. Removing an account does not necessarily revoke provider access; revoke it with the provider when needed.

## Website

The static landing page lives in [`website/`](website/README.md). It deploys directly to Cloudflare Pages with Wrangler; no build step is required.

## Project layout

```text
Sources/Usage/          macOS app and interface
Sources/UsageCore/      Provider integrations and models
Tests/UsageCoreTests/   Tests
Support/Info.plist      App bundle configuration
scripts/build-app.sh    Build and package the app
website/                Static landing page
```
