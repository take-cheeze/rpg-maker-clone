# 42. Cache proxied archives in R2

Date: 2026-08-12

## Status

Accepted

## Context

The CORS proxy (`cors-proxy/worker.js`, [ADR 10](0010-cors-proxy-cloudflare-worker.md))
fetches a game archive from GitHub (or any `.zip` host) on every single load and
streams it straight through — there is no server-side reuse. The loader already
caches the *decoded* bytes in the browser's Cache API (`src/shell.html`,
`cacheGet`/`cachePut`), but that only helps repeat loads from the *same*
browser profile; a different browser, a different device, or a cleared cache
means the full archive is re-downloaded from the origin host every time.

For a popular or frequently-reloaded project this means:

- repeated full-archive pulls against `codeload.github.com`, which is rate
  limited and can throttle or block the Worker's outbound IP under load;
- slower loads than necessary — the Worker refetches and re-streams bytes it
  has already seen, instead of serving them from Cloudflare's own edge storage.

Cloudflare Workers can bind an **R2 bucket** directly (no separate API calls,
no egress fee between Worker and R2) and R2 supports range reads (`get(key,
{range})`), which lets a cache serve the loader's existing plain-GET traffic
today and any future Range-based consumer without re-implementing partial
content handling.

The complication R2-backed caching introduces: the archive at a given URL is
not necessarily immutable. A GitHub branch archive (`codeload.github.com/.../
zip/refs/heads/main`) tracks whatever is on the branch *right now* — the URL
never changes but the bytes behind it do. Caching those bytes forever would
silently serve a stale project after the source repo is updated.

## Decision

Add an **optional** R2 cache to the existing Worker, off by default like the
three access-control vars ([ADR 10](0010-cors-proxy-cloudflare-worker.md)):

- `ARCHIVE_CACHE` — an R2 bucket binding. Unbound (the default —
  `wrangler.toml`'s `[[r2_buckets]]` block ships commented out) means every
  request proxies straight through exactly as before; nothing about caching
  runs, so existing deployments are unaffected until someone opts in.
- **Cache key**: SHA-256 of the resolved target URL. Keying on the target
  (not the caller's `?key=` or origin) means one cache entry serves every
  caller and both loader prefix styles (`?url=` and path-style resolve to the
  same target URL, hence the same key).
- **Freshness, not permanence**: each entry carries a `cachedAt` timestamp in
  R2 customMetadata, checked against `CACHE_TTL_SECONDS` (default 3600 = 1
  hour) on every lookup. An expired entry is treated as a miss and
  transparently re-fetched-and-replaced — this is the mitigation for the
  branch-archive staleness problem above. A user pointing at content that
  changes rarely (a tagged release) can raise the TTL; one pointing at a
  fast-moving branch can lower it.
- **Whole-object writes only**: the cache is populated only from a plain GET
  (no `Range` header) that came back `200`. A Range request — the proxy
  forwards them, though the loader itself never sends one — is proxied
  through untouched on a miss, so a cache entry is never a partial object.
  Reads are not so restricted: once an entry exists, Range requests against
  it are served straight from R2's own ranged `get()`, computing
  `Content-Range` from the range R2 actually resolved (open-ended and suffix
  ranges included).
- `CACHE_MAX_BYTES` — an optional cap; a response whose `Content-Length`
  exceeds it is still proxied to the client but not written to R2, so one
  oversized archive can't be forced into blowing past a bucket's expected
  footprint.
- The write to R2 happens off the response's critical path: the upstream
  body is `tee()`'d, one branch streamed to the client immediately, the
  other handed to `ctx.waitUntil(bucket.put(...))` so the client never waits
  on the cache write, and a write failure (network hiccup, over quota) is
  logged and swallowed rather than breaking the response already in flight.
- An `X-Proxy-Cache: HIT | MISS | BYPASS` response header (added to
  `Access-Control-Expose-Headers`) makes the cache's behaviour observable
  from `curl` or the browser without needing the Cloudflare dashboard.

## Consequences

- Repeat loads of the same archive — by anyone, from any browser — are served
  from Cloudflare's edge instead of re-hitting GitHub, cutting both load time
  and the Worker's exposure to `codeload.github.com` rate limiting.
- Still opt-in and backward compatible: a deployment that never creates the
  bucket or uncomments the `[[r2_buckets]]` block keeps the exact behaviour
  from ADR 10, byte for byte — `env.ARCHIVE_CACHE` is `undefined` and every
  cache branch is skipped.
- **Freshness is time-based, not validated against the origin.** The Worker
  never asks GitHub "has this changed?" (no conditional `If-None-Match`
  request) — it just trusts the TTL. This is simpler and keeps the whole
  point of caching (skip the upstream round trip) intact, but it means a
  branch archive can serve up to `CACHE_TTL_SECONDS` old after a push. Users
  who need stronger freshness guarantees should point at an immutable
  ref (a tag/release zip) or lower the TTL; a validated (ETag-conditional)
  cache is a possible follow-up if that turns out not to be enough.
- New R2 costs are the user's own account's (free tier: 10 GB storage, no
  egress fee to a Worker in the same account) — nothing changes for the
  project's CI or build, this remains a hand-deployed, optional Worker per
  ADR 10.
- `docs/cors-proxy.md` gains a "Caching archives in R2" section covering
  bucket creation, enabling the binding, and the two tuning vars.
