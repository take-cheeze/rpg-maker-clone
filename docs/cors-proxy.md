# Deploying the CORS proxy to Cloudflare Workers

The web loader ([`src/shell.html`](../src/shell.html)) can download an RPG Maker
project from a `.zip` URL or a GitHub repo. Browsers block those cross-origin
reads unless the host sends CORS headers, and GitHub does not — so the loader
prepends a **CORS proxy prefix** to the target URL. The proxy fetches the file
server-side (where the same-origin policy doesn't apply) and re-serves the bytes
with `Access-Control-Allow-Origin: *`.

This guide deploys that proxy as a **Cloudflare Worker** using the code in
[`cors-proxy/worker.js`](../cors-proxy/worker.js). Cloudflare's free plan is
plenty for personal use (100k requests/day).

## What you need

- A Cloudflare account (free): <https://dash.cloudflare.com/sign-up>
- Node.js 18+ installed locally (for the `wrangler` CLI)

No credit card and no custom domain are required — the Worker gets a free
`*.workers.dev` URL.

## Deploy in 4 steps

Everything runs from the `cors-proxy/` directory:

```sh
cd cors-proxy

# 1. Log in to Cloudflare (opens a browser to authorize wrangler).
npx wrangler login

# 2. Deploy. wrangler reads wrangler.toml and uploads worker.js.
npx wrangler deploy

# 3. wrangler prints the deployed URL, e.g.
#    https://rpg-maker-cors-proxy.<your-subdomain>.workers.dev
```

**4. Point the loader at it.** Open the game page, expand *Load from a URL or
GitHub*, and put your Worker URL in the **CORS proxy prefix** field in either
style:

- **Query style** (recommended): `https://rpg-maker-cors-proxy.<sub>.workers.dev/?url=`
- **Path style**: `https://rpg-maker-cors-proxy.<sub>.workers.dev/`

The loader builds the final request itself: with a prefix ending in `?`, `&`, or
`=` it appends the URL-encoded target; otherwise it appends the raw target after
a `/`. The Worker understands both. The prefix is remembered across reloads and
travels in the shareable `?proxy=…` query, so you only type it once.

## Verify it works

```sh
# A tiny public zip through the proxy — should return 200 with a CORS header.
curl -sI "https://rpg-maker-cors-proxy.<sub>.workers.dev/?url=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("https://codeload.github.com/octocat/Hello-World/zip/refs/heads/master"))')" | grep -i -E 'HTTP/|access-control-allow-origin'
```

You should see an `access-control-allow-origin: *` header. Then load a real
project in the page — e.g. put an `owner/repo` in the URL field with your proxy
prefix set — and it should download and start.

## Restricting use to yourself (recommended)

As written the Worker proxies **any** http(s) URL for **anyone** who knows its
URL — fine for a private link you don't share, risky otherwise (an open proxy
can be abused as an anonymizing relay, and it burns your request quota). Three
independent, opt-in controls narrow it down; all are unset by default:

| Variable | Limits | Notes |
| --- | --- | --- |
| `ALLOWED_HOSTS` | which **target hosts** may be fetched | Caps abuse-as-relay. Always worth setting. |
| `AUTH_KEY` | **who** may call it — only requests with your secret key | The real "only me" lock. |
| `ALLOWED_ORIGINS` | which **web page** may call it | Softer: your game page is public, so anyone who opens it could use the proxy. |

### For personal ("only me") use

Set a **secret key** plus a **host allowlist**. The key is the lock; the host
list limits the blast radius if the key ever leaks.

```sh
cd cors-proxy

# 1. Store the secret (encrypted; prompts for the value). Pick a long random string.
npx wrangler secret put AUTH_KEY

# 2. Restrict target hosts, then deploy.
npx wrangler deploy --var ALLOWED_HOSTS:".github.com,codeload.github.com,objects.githubusercontent.com"
```

Then set the loader's **CORS proxy prefix** to a query-style prefix that carries
the key (the loader appends the encoded target after the trailing `=`):

```
https://rpg-maker-cors-proxy.<sub>.workers.dev/?key=YOUR_SECRET&url=
```

Every request without a matching `?key=` gets a `403`. Because the key must ride
in the query string, use the **query prefix style** (not path style) when
`AUTH_KEY` is set.

> **Keep the key private.** The prefix — key included — is saved in your
> browser's `localStorage` and mirrored into the address bar as `?proxy=…`, so
> **don't share a bookmarkable link** from a page where you've set it; that link
> carries your key. To rotate the key, run `wrangler secret put AUTH_KEY` again.

### Or: lock it to your game page

If you'd rather not manage a secret, restrict by **origin** instead — only your
deployed page's browser can use the proxy (its GitHub Pages origin, plus
`localhost` for local testing):

```sh
npx wrangler deploy \
  --var ALLOWED_HOSTS:".github.com,codeload.github.com,objects.githubusercontent.com" \
  --var ALLOWED_ORIGINS:"https://<owner>.github.io,http://localhost:8000"
```

A disallowed origin gets a `403`, and successful responses are CORS-scoped to
the caller's origin instead of `*`. This stops other websites from using your
proxy, but not other visitors to your own (public) page — combine it with
`AUTH_KEY` if you need both.

### About `ALLOWED_HOSTS`

Comma-separated; a leading dot matches subdomains (`.github.com` matches
`codeload.github.com`). GitHub archive downloads flow through
`codeload.github.com` and can redirect to `objects.githubusercontent.com`, so
include both; add any other zip hosts you use. You can also set these vars by
uncommenting the `[vars]` block in
[`wrangler.toml`](../cors-proxy/wrangler.toml) instead of passing `--var`.

## Caching archives in R2 (optional)

Without it, every load re-fetches the archive from the origin host — even a
repeat load of a project you already played, from a different browser or
device than last time (the loader's own browser-side cache only covers the
*same* browser). Binding an R2 bucket lets the Worker serve repeat loads
straight from Cloudflare's edge instead: faster, and it stops hammering
`codeload.github.com`'s rate limit. Off by default, like the access controls
above — rationale in
[`docs/adr/0042-cors-proxy-r2-cache.md`](adr/0042-cors-proxy-r2-cache.md).

```sh
cd cors-proxy

# 1. Create the bucket (one-time; free tier covers 10 GB storage).
npx wrangler r2 bucket create rpg-maker-cors-proxy-cache
```

Then uncomment the `[[r2_buckets]]` block in
[`wrangler.toml`](../cors-proxy/wrangler.toml) and deploy again:

```sh
npx wrangler deploy
```

That's it — no loader changes needed, and no change to the proxy prefix you
already configured. A `curl -sI` against the same URL twice shows the effect:
the first response carries `x-proxy-cache: miss`, the second `x-proxy-cache:
hit` (also exposed to browser JS via `Access-Control-Expose-Headers`, if you
want to show it in the loader's log).

Two vars tune it, set alongside `ALLOWED_HOSTS` etc. in the `[vars]` block:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CACHE_TTL_SECONDS` | `3600` (1 hour) | How long a cached entry is served before being treated as stale and re-fetched. A GitHub **branch** archive's URL never changes even though its contents do, so the cache revalidates on a timer rather than keeping entries forever. Point at a release/tag zip (which *is* immutable) and raise this; point at a fast-moving branch and lower it. |
| `CACHE_MAX_BYTES` | unset (no limit) | Skip *caching* (the response is still proxied normally) an archive whose `Content-Length` exceeds this many bytes, to cap what lands in the bucket. |

Only whole-file downloads populate the cache (the loader only ever does plain
`GET`s — see `src/shell.html`'s `fetchZip()` — so this covers it entirely); a
`Range` request is proxied straight through without touching R2 on a cache
miss, but *is* served from R2 once an entry exists, computed from the cached
bytes.

## Updating

Edit [`cors-proxy/worker.js`](../cors-proxy/worker.js) and run
`npx wrangler deploy` again — same URL, new code. Roll back from **Workers &
Pages → your Worker → Deployments** in the Cloudflare dashboard.

## How the Worker behaves

- **Methods**: `GET`, `HEAD`, and `OPTIONS` (CORS preflight). Anything else → `405`.
- **Range requests** are forwarded, so large archives can stream/resume, and
  `Content-Range` / `Accept-Ranges` are exposed to the browser.
- **Redirects** are followed server-side (GitHub's codeload endpoint 302s to a
  signed URL).
- **Access checks** (all opt-in): a disallowed origin, a missing/invalid
  `AUTH_KEY`, or a blocked target host each return `403`. The CORS preflight
  (`OPTIONS`) is exempt from the key check but still honours the origin check.
- **R2 cache** (opt-in, see above): when bound, a fresh cache hit is served
  from R2 without an upstream fetch (`X-Proxy-Cache: hit`); a miss fetches
  and streams through as usual while also writing to R2 in the background
  (`X-Proxy-Cache: miss`).
- **Errors** come back with CORS headers and a plain-text reason (`400` bad
  target, `403` blocked/unauthorised, `502` upstream failure), so the loader
  shows a real message instead of an opaque network error.

## Notes and alternatives

- **Not the same as the Cloudflare *Pages* setup.** [`deploy.md`](deploy.md)
  covers publishing the game *page* (GitHub Pages + Cloudflare Pages previews).
  This proxy is a separate, optional Worker for *downloading projects at runtime*.
- **No proxy needed for local files.** *Open a local project* reads a `.zip`
  straight off disk with no network, so the proxy only matters for URL/GitHub
  loads.
- **Public proxies** like `https://corsproxy.io/?url=` work too (that's the
  field's placeholder), but they rate-limit and can disappear; your own Worker is
  more reliable and, with the access controls above, not abusable.
