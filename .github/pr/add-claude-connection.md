# auth: add ANTHROPIC_AUTH_TOKEN bearer auth and ANTHROPIC_BASE_URL

Add a third connection method using `ANTHROPIC_AUTH_TOKEN` (Bearer auth) and
support `ANTHROPIC_BASE_URL` for custom API endpoints. This enables `ah` to
connect through proxies or alternative endpoints that accept Bearer tokens.

## Changes

- `lib/ah/auth.tl` - add `ANTHROPIC_AUTH_TOKEN` as bearer credential type between OAuth and API key
- `lib/ah/api.tl` - read `ANTHROPIC_BASE_URL` env var for endpoint override
- `lib/ah/test_auth.tl` - fix existing tests to save/restore new env var, add bearer-specific tests
