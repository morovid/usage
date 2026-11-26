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

Run the app bundle rather than `swift run` so macOS notifications work. Local builds produce only `dist/Usage.app`, signed with the Morovid Developer ID (`R973J5PQW7`) by default to preserve Keychain trust across builds. To override the identity:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh scripts/build-app.sh
```

Use `SIGN_IDENTITY=-` only for ad-hoc builds; these do not preserve Keychain trust across rebuilds. Open `Package.swift` in Xcode to edit or debug the package.

### Release DMG (local notarization)

Once, store Apple notarization credentials locally. Use your Apple Developer Apple ID and an
[app-specific password](https://support.apple.com/102654), not your normal password:

```sh
xcrun notarytool store-credentials usage-notary --apple-id "you@example.com" --team-id R973J5PQW7
```

Enter the app-specific password when prompted. No credentials belong in the repository.
The Apple ID must have access to that developer team.

Then build a release:

```sh
zsh scripts/release.sh 1.0.0
```

This builds and signs `dist/Usage.app`, sets its version, notarizes and staples it,
then creates, signs, notarizes and staples `dist/Usage-1.0.0.dmg`. The image contains
the app and an Applications shortcut. Verification must pass before the final DMG
is published into `dist/`. A `.dmg.sha256` checksum and notarization submission
JSON files are saved alongside it. Existing DMGs are not overwritten.

Optional environment overrides: `SIGN_IDENTITY`, `NOTARY_PROFILE` (default:
`usage-notary`), and `BUILD_NUMBER` (default: the release version).
The source `Support/Info.plist` is not modified. Builds target the current Mac's
architecture; this does not create a universal binary.

## Connect accounts

Open **Accounts** from the menu-bar icon, select a provider, and follow the sign-in or verification prompts. Multiple accounts per provider are supported.

| Provider | Connection | Reading |
| --- | --- | --- |
| Claude | Claude Code CLI sign-in, session import, or OAuth token | Subscription usage |
| OpenAI subscription | ChatGPT sign-in through the official Codex CLI | Reported ChatGPT/Codex quotas |
| Kimi subscription | Global Kimi browser sign-in or subscription API key | Kimi Code quotas |
| OpenCode | OpenCode Go workspace API key | Go usage |
| GitHub Copilot | GitHub device sign-in | Available Copilot quotas |
| Anthropic API | Claude Console organization Admin API key with analytics access | Organization month-to-date cost before credits |
| OpenAI API | Organization Admin API key with costs-read access | Organization month-to-date spend |
| Moonshot API | Global Open Platform API key | Available balance |
| DeepSeek API | DeepSeek API key | Available balance (DeepSeek has no subscription quotas) |

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
scripts/make-icon.swift Regenerates Support/AppIcon.icns from the website favicon
website/                Static landing page
```
