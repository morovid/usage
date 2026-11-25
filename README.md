# Usage

A native SwiftUI/AppKit macOS menu-bar app for AI subscription usage and Anthropic/OpenAI/Moonshot API billing readings. Requires **macOS 14+** and **Swift 6 / Xcode 16+** to build. No third-party dependencies.

## Build and run

```sh
swift test
zsh scripts/build-app.sh
open dist/Usage.app
```

Run the **app bundle**, not `swift run`: macOS notifications need a properly identified application bundle. The script signs locally with an ad-hoc signature. For stable Keychain access across builds and distribution, use your signing identity:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh scripts/build-app.sh
```

Distribution to other Macs also requires Apple's normal hardened-runtime/notarization workflow; this script produces a local build, not a notarized release. Open `Package.swift` in Xcode to edit/debug the Swift package.

## Using the app

- **Click the menu-bar chart icon:** account email/name, provider, and usage progress bars.
- **Right-click / Control-click:** About Usage, Accounts…, Quit Usage.
- **Accounts:** add, edit, refresh, or remove accounts. Multiple accounts per provider are supported.
- While Accounts is open (including minimized), Usage appears in the Dock and Cmd-Tab. Closing it returns Usage to menu-bar-only mode without stopping monitoring. Startup does not open a window.
- The popup uses a square, grayscale status panel with provider/tag and compact bars side by side. Bars retain muted usage colors: slate blue below 40%, forest green at 40–69%, burnt amber at 70–89%, and muted crimson at 90%+. Hover a credit bar to see `current / max` inline. Values have no badge background; text contrast adapts to the filled and unfilled bar portions in light/dark mode. The bottom-right gear opens Accounts. Click outside or press Escape to dismiss.
- The shortest usage window is shown above the longest. Accounts displays all intermediate windows and model-specific caps. At a shared duration, the compact view selects the highest usage. These are read-only progress meters, not editable sliders.
- Labels reflect the provider's actual window: a weekly quota is never called monthly.
- All windows, including collapsed ones, are checked for notifications.
- Healthy accounts refresh every **60 seconds while the Mac is awake**. Wake triggers a refresh. Failures back off to at most 15 minutes; manual Refresh bypasses the cooldown. No inference requests are made.
- Failed requests keep the last successful reading, visibly marked stale. No data is fabricated.

## Connect accounts

| Provider | Authentication | Usage source |
| --- | --- | --- |
| Anthropic → Claude subscription | Official Claude Code sign-in, session import, or pasted OAuth token | `GET https://api.anthropic.com/api/oauth/usage` |
| OpenAI | Browser sign-in with ChatGPT through the official Codex CLI | Codex app-server `account/rateLimits/read` |
| Moonshot | Global Kimi browser sign-in (OAuth device flow), or subscription API key | `GET https://api.kimi.ai/coding/v1/usages` (legacy China keys: `api.kimi.com`) |
| OpenCode | Console sign-in followed by verified Go workspace API key | `GET https://opencode.ai/inference/go/v1/usage` |
| GitHub Copilot | Browser sign-in with the Usage GitHub App (device flow) | `GET https://api.github.com/copilot_internal/user` |
| OpenAI → API key | Organization Admin API key with costs-read access | `GET https://api.openai.com/v1/organization/costs` |
| Moonshot → API key | Global Open Platform API key | `GET https://api.moonshot.ai/v1/users/me/balance` |
| Anthropic → API key | Claude Console organization Admin API key with analytics access | `GET https://api.anthropic.com/v1/organizations/analytics/cost` |

Anthropic, OpenAI, and Moonshot each have an **Account type: Subscription / API key** selector beneath the existing Provider dropdown (Anthropic labels the subscription option **Claude subscription**). These are separate monitored accounts; changing an existing account's type is intentionally disabled to avoid mixing credentials and readings. Add another account to monitor both. Existing accounts retain their subscription behavior.

### API-key accounts (Anthropic, OpenAI, and Moonshot)

1. Choose **Anthropic**, **OpenAI**, or **Moonshot**, then **API key**.
2. Enter an account label and the appropriate key. API accounts do not require an email address.
3. Click **Verify and add account**. Usage checks the actual billing endpoint before saving the key in Keychain. It does not make an inference request or start a CLI.
4. Edit an API account to replace its key; leave the key blank to keep it. Saving re-verifies billing access.

**OpenAI:** requires an **organization Admin API key**, created by an organization owner in [organization settings](https://platform.openai.com/settings/organization/admin-keys), with access to read costs. An ordinary project/model API key cannot read organization billing. Admin keys are sensitive: grant only the minimum permissions available for reading costs. Usage performs only `GET /v1/organization/costs`. It sums all returned daily buckets/pages from the beginning of the current calendar month in **UTC** through the current time and shows **organization-wide month-to-date spend in USD**. This is not per-key spend, a prepaid balance, a provider spending cap, or ChatGPT/Codex quota usage. Billing updates may be delayed. No undocumented browser/session billing endpoints are used.

**Moonshot:** accepts a **Global Open Platform API key**, obtained from the [API dashboard](https://platform.kimi.ai/console/api-keys). It shows the provider's **available balance in USD**, plus cash and voucher components in Accounts. Zero or negative reported balances are preserved. This is not Kimi Code subscription usage or a monthly consumption total. Global keys use `api.moonshot.ai`; neither China API keys nor Kimi Code subscription keys are accepted for this mode. There is no region discovery/fallback.

**Anthropic:** requires a **Claude Console organization Admin API key** with analytics access. Normal inference keys and Claude subscription tokens do not provide this billing access. Individual Console accounts must first set up an organization; claude.ai Team subscriptions alone are not eligible. Usage reads the current [Usage and Cost Analytics API](https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api), sending `x-api-key`, `anthropic-version: 2026-10-21`, and `anthropic-beta: analytics-usage-cost-2026-08-24`. It queries hourly costs from the current UTC month's start, follows all pages, and converts the provider's decimal-string **cents** to USD. This is organization-wide cost after discounts and **before credits**, not your remaining balance or Claude subscription quota. Priority Tier commitment fees are excluded. Time boundaries round down to the hour; analytics typically lag 4 hours and can lag 24 hours or be revised later. Accounts shows the provider's data-refresh time. A response with no data-refresh timestamp is unavailable, not zero.

Money readings appear in both the popup and Accounts, identified as **Anthropic API**, **OpenAI API**, or **Moonshot API**. These endpoints do not provide a suitable quota denominator: Usage does not invent percentages, progress bars, or 70%/100% alerts for API accounts. Missing/malformed billing data, rejected keys, and incomplete pagination remain errors; the last successful reading stays visibly stale. A valid empty OpenAI cost result, or an empty Anthropic result with a data-refresh timestamp, is zero spend. API integrations are fixture/mock-tested, not live-verified with user keys.

References: [OpenAI Costs API](https://platform.openai.com/docs/api-reference/usage/costs), [Moonshot balance API](https://platform.moonshot.ai/docs/api/balance).

### Claude / Anthropic

1. Install the official Claude Code CLI. Usage does not install it.
2. In Usage → Accounts → Add account → Anthropic → **Claude subscription**, enter the account email.
3. Click **Sign in with Claude Code** and finish in your browser. Usage runs only `claude auth login`, then imports an access-token-only copy and verifies subscription usage access. This signs in to **your normal Claude Code session**, not an isolated account. The UI discloses this before sign-in.
4. Click **Add account**. Usage stores the imported access token in its own Keychain item.

The helper receives a small environment allowlist: no inherited API keys, OAuth tokens, gateway overrides, proxies, `NODE_OPTIONS`, or custom `CLAUDE_CONFIG_DIR`. Executable discovery checks `~/.local/bin/claude`, Homebrew paths, and absolute PATH entries. CLI output is discarded, never logged or shown. Cancel stops the pending helper and the login times out after ten minutes, but neither action undoes an already completed official CLI login.

**Fallback:** run `claude auth login` yourself in Terminal, then click **Import Claude Code session…**. This explicitly reads `~/.claude/.credentials.json`, falling back to the `Claude Code-credentials` macOS Keychain item. macOS may request permission. The fallback also supports CLI versions that require an interactive terminal. You can still paste an existing OAuth access token.

Usage does **not** copy refresh tokens or directly rewrite Claude's credentials; the explicit sign-in button delegates credential changes to the official CLI. When an imported access token expires, let Claude Code refresh it, then Edit → Import again or sign in again. Pasted OAuth tokens have the same limitation. Removing a Usage account does not sign out Claude Code. The helper lifecycle is tested with mock executables; real browser sign-in and quota access remain unverified.

### OpenAI / Codex

1. Install the [official Codex CLI](https://developers.openai.com/codex/cli/). Usage does not install it automatically.
2. Choose **OpenAI** and click **Sign in with ChatGPT**.
3. Complete sign-in on OpenAI's page in your browser. The official CLI hosts the localhost callback and handles OAuth.
4. Usage fetches your account and verifies quota access, then displays a read-only **Account name** using the returned email (or “ChatGPT account” if no email is provided).
5. Click **Add account**. No access token, account ID, email entry, or custom allowance is required.

The dialog follows the minimal Copilot layout: Provider, a centered primary sign-in button before login, then a read-only account field after verification. The window and popup use their existing usage designs.

**What is monitored:** OpenAI's reported ChatGPT/Codex subscription quota windows, including additional metered buckets when provided. These are not a complete total of all ChatGPT messages, token activity, API billing, or usage across every ChatGPT product. Percentages and reset dates come from OpenAI, and durations/labels are derived from the response (for example, five-hour and weekly). No monthly denominator is invented. Missing windows show an error rather than fabricated zero usage.

Usage starts `codex app-server --listen stdio://` with its own client identity, a separate `CODEX_HOME` per monitored account under `~/Library/Application Support/Usage/OpenAI/<UUID>`, and `cli_auth_credentials_store="keyring"`. The official CLI owns access/refresh credentials in its secure store; Usage does not read/copy those tokens. The default `~/.codex` login/configuration and other Usage accounts are not overwritten. The helper receives only a small environment allowlist, not inherited OpenAI keys or gateway overrides.

The helper stays available for minute-by-minute account/limit reads and Codex-managed token renewal. Usage never starts inference, agent threads, tools, or filesystem requests. Closing Accounts keeps monitoring active; quitting Usage closes its helper connections. Cancelling an unfinished sign-in discards only the isolated Usage session. Removing a managed account asks Codex to log out of that isolated session, not your normal CLI account. If Codex is unavailable or cleanup fails, revoke the session in your OpenAI account as needed.

Executable discovery checks `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, the Codex app's resource path, and absolute PATH entries. This build was compiled with codex-cli 0.166.0 available, but browser sign-in and your account's quota access have not been live-verified.

This app-server authentication route is intended here for a **local/personal integration**. OpenAI documents restrictions for commercial/hosted use and recommends newer Sign in with ChatGPT registrations for those products. Do not distribute this as a commercial integration without reviewing the current [authentication guidance](https://developers.openai.com/codex/app-server/#auth-endpoints) and obtaining the appropriate registration/approval.

Existing imported `auth.json` and manually saved token accounts remain readable for backward compatibility; newly added accounts use the managed browser flow. Expired legacy tokens still require replacing the account with a new managed login.

### Kimi / Moonshot

1. Choose **Moonshot**. New accounts default to **Global · api.kimi.ai**.
2. Click **Sign in with Kimi**. Usage copies and displays the device code and opens Kimi's global authorization page.
3. Approve sign-in in your browser. Usage retrieves your account name and verifies Kimi Code quota access.
4. Click **Add account**. Tokens and rotating refresh credentials are stored only in Usage's Keychain.

Sign-in and renewal use `https://auth.kimi.ai/api/oauth/device_authorization` and `/api/oauth/token`; account lookup uses `https://api.kimi.ai/coding/v1/me`. There is no China-region discovery or fallback. No CLI installation, password collection, cookies, or inference requests are involved. Cancel stops pending authorization; **Edit → Sign in again with Kimi** replaces an expired/revoked session. Removing the account deletes local credentials, not the authorization at Kimi.

The protocol and public client ID (`17e5f671-d194-4dfb-9706-5516cb48c098`) come from MoonshotAI's published [Kimi OAuth toolkit](https://github.com/MoonshotAI/kimi-code/tree/main/packages/oauth). Requests identify as `Usage/1.0`, not as the official CLI. This is not a separately registered Usage OAuth client: provider acceptance and third-party/distribution policy are not guaranteed. The flow is mock-tested, **not live-verified with user credentials**. If Kimi rejects authorization, use **Use a subscription API key instead** rather than impersonating the CLI.

Existing API-key accounts are preserved. The China selector remains available for manual subscription keys only. General Moonshot pay-as-you-go keys do not expose these limits.

### OpenCode

1. Choose **OpenCode**, enter an account/workspace name, and click **Sign in to OpenCode Go**.
2. Sign in to the Console and create/copy a workspace API key covered by Go.
3. Paste it into Usage and click **Verify and add account**. Usage calls the documented `GET https://opencode.ai/inference/go/v1/usage` endpoint before saving the key to Keychain. Editing/replacing a key also re-verifies access.

This is a **guided console sign-in plus API-key connection**, not an embedded OAuth flow: browser sign-in alone does not authorize Usage. OpenCode documents keys as the Go connection method. No CLI credential database is read and no inference requests are made. OpenCode Zen-only accounts and keys without a Go entitlement cannot connect. Existing saved keys remain readable. See the [Go connection and usage documentation](https://opencode.ai/docs/console/go/).

### GitHub Copilot

1. Select **GitHub Copilot** in the account editor and click **Sign in with GitHub**.
2. Usage copies the eight-character code to the clipboard, displays it centered, and brings the app to the front. It opens `https://github.com/login/device` in your browser without intentionally switching focus away from Usage.
3. Switch to the GitHub page, paste the code, choose your account, and approve Usage. A **Copied** hint appears for five seconds; clicking the code selects/copies it again. The dialog's Cancel button cancels the pending sign-in.
4. Usage retrieves your GitHub username and tests quota access. Your username appears in a read-only **Account name** field beneath Provider, replacing the sign-in button. If GitHub reports consumed credits but no usable allowance, Usage asks for your **monthly allowance in GitHub credits**. Enter the amount, then click **Add account**.

No token copying, client secret, backend, or callback URL is needed. The public GitHub App Client ID is `Iv23li89IJLYqBiDzGoi`, configured in `Sources/UsageCore/GitHubAuth.swift`. The registration must have **Enable Device Flow** enabled. Usage requests expiring user tokens (`offline_access`) and stores the access token, refresh token, expiry dates, and client ID only in Keychain. Refreshes are serialized per account and replacement credentials are saved before the next usage request. An expired/revoked refresh token requires **Edit → Sign in again with GitHub**. Existing token-only credentials remain readable.

Usage reads finite monthly premium/credit, chat, and completion quotas from GitHub's internal Copilot endpoint. Unlimited and zero-entitlement categories are omitted rather than displayed as exhausted. Older free-plan count responses are also supported. Enterprise Server/custom hosts are not implemented.

When GitHub supplies consumption but no finite allowance, a positive user-entered monthly allowance allows monitoring to proceed. The popup shows the computed percentage and reveals consumed/allowed credits on hover; Accounts displays the credit values directly. Notifications at 70% and 100% explicitly refer to the user-provided allowance. This does not enforce or change any GitHub billing limit. Use the same GitHub credit units as your organization's allowance, not dollars, token counts, or legacy request counts. You can edit the saved allowance later; usable GitHub-reported limits always take precedence. Repeated counters in premium/chat/completions are never summed; the premium counter is preferred.

**Important:** a GitHub App user token can successfully sign in and still be rejected by the undocumented Copilot quota endpoint. A manual allowance cannot fix missing consumption, unauthorized requests, or an ended subscription. Those failures remain errors and prevent connecting a new monitored account. Do not add repository/admin/inference permissions blindly to work around a rejection. The integration and authorization lifecycle are mock/fixture-tested, not live-verified with user credentials.

Missing quotas now show allowlisted response diagnostics without tokens or raw response bodies. Organization-funded usage is not included in personal billing reports, and organization/enterprise billing reports require separate billing access. See [Copilot usage research](docs/copilot-usage-research.md) for possible integration paths and limits.

### Account labels

Claude asks for **Account Email**. OpenAI retrieves its read-only account name through the authenticated Codex account endpoint. Global Kimi browser sign-in retrieves a read-only name from `/me`; manual Kimi keys and OpenCode Go ask for **Account Name**, with no email-format validation. Copilot obtains its username automatically from authenticated `GET /user`. Labels appear on cards and notification subtitles.

### OAuth scope and API caveats

GitHub uses Usage's own GitHub App registration and device authorization flow. OpenAI delegates authentication to the official Codex app-server. Global Kimi uses the public client configuration in MoonshotAI's published OAuth toolkit, subject to the acceptance/policy caveat above. Claude delegates explicit sign-in to the official CLI and imports an access-token-only copy. OpenCode Go uses its documented API-key connection method. Usage does not impersonate CLIs, read browser cookies, or collect passwords. Further provider authentication changes require checking each provider's current registration and usage-access policies.

Several usage endpoints are undocumented or evolving. These integrations are implemented against observed response schemas, **not guaranteed or live-verified with user credentials**. Errors and unrecognized schemas are shown as unavailable rather than zero. Subscription accounts track quotas; separately selected Anthropic/OpenAI/Moonshot API accounts track the documented billing readings described above. Availability depends on your plan and the provider's current access policy.

Kimi's count-based `usage` / `limits` fields take precedence over ratio fields when both describe the same window: some legacy responses report contradictory zero ratios. Modern monthly total/code pools are recognized separately.

## Notifications

Usage requests notification permission at startup if you have not already made a choice. Enable banners/sounds for Usage in **System Settings → Notifications** as desired. If permission was previously denied, macOS requires enabling it there rather than showing another permission prompt.

Example:

> **Your Anthropic usage is 73%**  
> user@example.com  
> 5-hour limit is approaching.

- Warn at **70% or above**, then again at **100%**.
- A jump straight to 100% produces only the exhausted alert.
- Notifications are deduplicated per account/window and persisted across launches.
- They rearm when a reset boundary has passed and the provider reports a new window, or usage falls below 70%.
- Expired provider windows do not trigger fresh notifications.
- Account email/name is the notification subtitle. macOS lock-screen preview and Focus settings determine visibility/delivery.
- Notifications are always enabled for all accounts when macOS permission is granted; older saved per-account opt-outs are ignored. Use System Settings to control notification delivery.

## Privacy and files

- Pasted/imported secrets: macOS Keychain, service `app.morovid.Usage.credentials`.
- Successfully saved/read credentials are cached in memory for this app process. Minute-by-minute polling does not reread Keychain once cached. Background reads/writes use a non-interactive authentication context: if permission is needed, polling shows an error instead of repeatedly opening a system dialog. In Accounts, explicitly choose **Allow Keychain access** for the affected account to authorize it once.
- macOS controls Keychain approval; Usage cannot grant itself access to another app's entries or bypass login-Keychain security. Existing items from older ad-hoc builds may need new approval. Select **Always Allow** only if you trust the installed Usage build. Signing successive builds with the same Apple Development/Developer ID identity preserves code identity; ad-hoc builds do not guarantee stable Keychain trust.
- OAuth refresh replacements update both the cache and Keychain. If a background Keychain write is blocked, the replacement is retained in memory and retried, avoiding repeated use of the old refresh token. Resolve Keychain approval before quitting so a pending rotated token can be saved.
- Account labels, linked file paths/IDs, and threshold history: `~/Library/Application Support/Usage/accounts.json` (owner-only permissions, atomic writes). The historical JSON key `email` also stores account names for compatibility.
- Usage snapshots are memory-only.
- Legacy linked Codex files are read only, never rewritten. New isolated Codex sessions are managed by the official CLI using its secure store; Usage persists only the session directory and account metadata.
- Direct HTTPS connections only to the selected provider; HTTP redirects are rejected to avoid forwarding credentials. Cookies and HTTP caching are disabled.
- No telemetry, intermediary backend, credential logs, or response-body logging.
- Removing an account deletes its saved Keychain credential and threshold history, but does not revoke provider access or sign out the official CLI. Revoke credentials in the provider console if needed.
- If the saved JSON cannot be loaded, the app preserves it and prevents edits instead of silently overwriting it. Back it up and repair/move it before reopening Usage.

The app is intentionally not sandboxed so it can link CLI files and access explicitly imported Keychain credentials. A Mac App Store/sandboxed build would require a separate entitlement and security-scoped-file-access design.

## Source layout

```text
Sources/Usage/          Menu-bar lifecycle, SwiftUI views, Keychain, polling, notifications
Sources/UsageCore/      Models, provider HTTP requests/parsers, threshold policy
Tests/UsageCoreTests/   Fixture-based parser and alert-policy tests
Support/Info.plist     App identity, version, agent (no Dock icon) settings
scripts/build-app.sh   Release build and local .app packaging
```

The About panel's author currently defaults to **Morovid**; update `Sources/Usage/App.swift` and `Support/Info.plist` for your preferred attribution/version before distributing.

### Integration references

- [OpenCode Go authentication and usage-window documentation](https://opencode.ai/docs/go/)
- [Codex upstream rate-limit response fixtures](https://github.com/openai/codex/blob/main/codex-rs/app-server/tests/suite/v2/rate_limits.rs)
- [Codex app-server authentication and rate-limit protocol](https://developers.openai.com/codex/app-server/)
- [Anthropic usage endpoint community reference](https://github.com/rohanprichard/claude-overnight/blob/main/docs/oauth-usage-endpoint.md)
- [Kimi count/ratio inconsistency report](https://github.com/MoonshotAI/kimi-code/issues/3951)
- [OpenCode Go usage endpoint reference](https://github.com/anomalyco/opencode/issues/43983)
- [GitHub Copilot quota API community reference](https://upld-internal.github.io/burnrate-copilot/research/copilot-api.html)
