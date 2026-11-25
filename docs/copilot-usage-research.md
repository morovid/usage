# Copilot usage access: personal and organization-funded accounts

Research checked against GitHub documentation on November 20, 2026. These are integration findings, not a claim of successful live access with the Usage GitHub App.

## What the reported error establishes

GitHub sign-in and `GET /user` succeeded. The quota request returned a successful HTTP response with no windows accepted by our parser. That does **not** establish whether the seat is personal, organization-funded, inaccessible to this token, unlimited, or using a newer credit-based schema.

No user credential or authenticated response was inspected during this research.

The updated parser distinguishes absent quota snapshots, unsupported/placeholder snapshots, credit billing without a finite allowance, explicitly unlimited categories, and an ended subscription. It shows an allowlisted diagnostic summary in the error. The summary includes only the presence/classification of known quota fields: it excludes access tokens, organization names, arbitrary keys/values, and raw response bodies.

### Implemented fallback: user-provided monthly allowance

When a valid `credits_used` counter is available but a usable premium allowance is absent, the account editor asks for a positive monthly allowance in GitHub credits. The GitHub identity and tokens remain in memory while the user supplies the amount; no second sign-in is required.

The manual allowance is persisted as account configuration. Each refresh uses the provider consumption counter against that denominator, labels it user-provided in the meter, and emits the normal threshold alerts with explicit user-provided-allowance wording. Provider-reported finite premium limits override the manual setting. The fallback does not bypass permissions, manufacture consumption, sum repeated quota counters, or alter GitHub's actual limits.

## Available data paths

### 1. Internal per-user quota endpoint

`GET https://api.github.com/copilot_internal/user`

This endpoint is used by Copilot tooling and community quota monitors. Observed Business-seat responses can contain the same `quota_snapshots.premium_interactions` fields as personal plans. Therefore an organization-funded license does **not** inherently mean the internal per-user route cannot work.

The Usage parser already accepts Business/Enterprise finite quotas without requiring a personal `copilot_plan` value. A Business-seat fixture now tests this explicitly.

Limitations:

- It is not a documented, stable third-party quota API.
- Support for arbitrary GitHub App user tokens is not guaranteed.
- Some community clients send editor/plugin compatibility headers. Those reports are not proof that the header is the cause of the current failure; we should not impersonate VS Code or borrow another application's OAuth identity.
- Credit-billed Business seats can return placeholder quotas and/or a `credits_used` amount without a usable finite allowance. A consumed amount alone is not a percentage. Do not treat a zero entitlement as 100% used or fabricate a plan allowance.
- A missing field is not zero usage. Unlimited categories are not exhausted quotas.

### 2. Public personal billing reports

Examples:

```text
GET /users/{username}/settings/billing/ai_credit/usage
GET /users/{username}/settings/billing/premium_request/usage
```

GitHub explicitly states that user-level billing endpoints return usage billed directly to that personal account. They exclude licenses managed/billed through an organization or enterprise. Therefore these are **not** a fallback for an organization-funded seat.

### 3. Public organization billing reports

Examples:

```text
GET /organizations/{org}/settings/billing/ai_credit/usage?user={username}&year={year}&month={month}
GET /organizations/{org}/settings/billing/premium_request/usage?user={username}&year={year}&month={month}
```

These are candidates when the organization is the billing owner and the authenticated user/app has the required billing access. Merely being a member with a Copilot seat does not grant this access. The permission required by the exact endpoint/token type must be checked before implementation; installation and organization approval may also be necessary.

Reports contain consumption/cost records, not necessarily the per-user enforced allowance needed for 70%/100% quota alerts. Do not substitute an organization-wide total or an assumed plan allocation for the user's remaining quota.

### 4. Public enterprise billing reports

Examples:

```text
GET /enterprises/{enterprise}/settings/billing/ai_credit/usage?user={username}&year={year}&month={month}
GET /enterprises/{enterprise}/settings/billing/premium_request/usage?user={username}&year={year}&month={month}
```

Enterprise-owned organizations may require reporting at the enterprise billing level. The current endpoint reference permits qualified administrators, billing managers, or delegated billing access and describes enterprise-installed GitHub App installation tokens with read access to enterprise billing.

GitHub's reporting tutorial still contains a broad classic-PAT prerequisite, while endpoint/token-reference pages describe additional GitHub App support. Treat this as documentation inconsistency, validate the particular endpoint and token type, and do not promise that our current user token can read enterprise reports.

This is an administrative integration, not a transparent workaround for ordinary members' permissions.

### 5. Seat-management and engagement metrics APIs

```text
GET /orgs/{org}/copilot/billing
GET /orgs/{org}/members/{username}/copilot
```

These report seat assignments, policies, and activity information. They do not provide a documented remaining quota/allowance denominator. Engagement metrics, suggestion counts, and last activity must not be presented as premium/credit quota consumption.

## Recommended next steps

1. Retry sign-in using the updated build and inspect the safe diagnostic text.
2. If snapshots are absent, investigate the GitHub App token's endpoint support and organization authorization/SSO policy. Do not infer missing subscription from absence alone.
3. If the response is credit-based with placeholders, determine whether an authenticated billing report can expose consumption and whether there is a trustworthy user-specific allowance/budget. Surface raw consumed credits separately if necessary; percentage alerts require a real denominator.
4. For an ordinary organization member, seek a supported self-usage interface from GitHub if the internal route does not expose quotas. Broader app permissions cannot grant privileges the user does not have.
5. If an owner/billing manager wants an administrative integration, explicitly configure the billing owner and read-only authorization before implementing report fetching. Do not query every organization automatically.

## Sources

- [Public billing usage API, including the personal vs organization billing distinction](https://docs.github.com/en/rest/billing/usage)
- [Enterprise billing usage API](https://docs.github.com/en/enterprise-cloud@latest/rest/billing/usage)
- [Automating usage reporting](https://docs.github.com/en/billing/tutorials/automate-usage-reporting)
- [Copilot seat-management API](https://docs.github.com/en/rest/copilot/copilot-user-management)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [Observed Business quota response (community example)](https://github.com/BerriAI/litellm/issues/18242)
- [Community implementation handling token-based placeholders](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift)
