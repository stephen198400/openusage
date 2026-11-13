# Droid

Tracks your Factory usage limits using the login from the droid CLI.

## What it tracks

Factory's Standard usage limits, the same bars as the Usage Limits section of Factory's usage page:

| Metric | Meaning |
|---|---|
| Session | Share of the rolling 5-hour limit used |
| Weekly | Share of the weekly limit used |
| Monthly | Share of the monthly limit used (On Demand by default) |

Each row counts down to its own window's reset. A window that hasn't started yet shows no reset time.

## Where credentials come from

The login droid saves in `~/.factory`, checked in the same order droid uses:

1. `auth.v2.loginkeychain`, unlocked with droid's key in your login keychain (`Factory CLI`)
2. `auth.v2.file` with its key file `auth.v2.key` (droid's on-disk store)

Access tokens last about a week. When one has expired, OpenUsage refreshes it and saves the new tokens back into the same store, so droid keeps working too.

## Troubleshooting

- **"Not logged in"** — run `droid` and sign in, then refresh.
- **"Session expired"** — the saved login can't be refreshed any more; run `droid` and sign in again.
- **"Login couldn't be read"** — the store exists but couldn't be unlocked (for example, the keychain item was removed). Sign in again with `droid`.

## Under the hood

`GET https://api.factory.ai/api/billing/limits` with the WorkOS access token (the same call droid makes for its own usage-limit warnings); the Standard pool's `fiveHour`, `weekly` and `monthly` buckets are used. Refresh is WorkOS `user_management/authenticate` with droid's client ID; the store is AES-256-GCM (`iv:tag:ciphertext`, base64).
