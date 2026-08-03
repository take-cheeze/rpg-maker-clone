# 9. CORS proxy as a Cloudflare Worker

Date: 2026-08-03

## Status

Accepted

## Context

The web loader (`src/shell.html`) can start a game from three sources: a local
`.zip` (no network), a direct `.zip` URL, and a GitHub `owner/repo` (resolved to
its `codeload` archive). The two network sources hit the browser's same-origin
policy: a cross-origin `fetch` of a zip only succeeds if the host returns CORS
headers, and GitHub's archive endpoint — like most `.zip` hosts — does not. So
those loads fail with an opaque network error unless the bytes come through a
**CORS proxy**.

The loader already has the client half of this: an optional *CORS proxy prefix*
field. It builds the final request in one of two shapes depending on the prefix
the user typed (`src/shell.html`):

- prefix ending in `?`, `&`, or `=` → `prefix + encodeURIComponent(url)`
  (query style, e.g. `https://…/?url=`)
- otherwise → `prefix.replace(/\/$/, '') + '/' + url` (path style)

What was missing was a documented, self-hostable proxy to point it at. The
field's placeholder names a public service (`corsproxy.io`), but public proxies
rate-limit, can vanish, and route your traffic through a third party. Users
asked how to run their own.

Options considered for hosting the proxy:

- **Cloudflare Worker** — free tier (100k req/day), a global edge runtime, a
  free `*.workers.dev` URL with no custom domain, and a one-command `wrangler
  deploy`. The project already uses Cloudflare (Pages previews, see
  `docs/deploy.md`), so it's a familiar dashboard.
- **A small Node/Deno server on a VPS or PaaS** — full control, but needs a
  host, TLS, and process management for what is a stateless byte-forwarder.
- **Serverless elsewhere** (AWS Lambda, Vercel, Netlify Functions) — all viable,
  but heavier setup than a Worker for the same result.

## Decision

Ship a ready-to-deploy Cloudflare Worker in `cors-proxy/` and document it in
`docs/cors-proxy.md`.

- `cors-proxy/worker.js` — an ES-module Worker that:
  - accepts **both** loader prefix styles: it reads the target from `?url=` when
    present, else from the raw path (`/<url>`), reconstructing any query the
    target carried;
  - handles the CORS **preflight** (`OPTIONS` → 204) and allows only
    `GET`/`HEAD` otherwise;
  - **forwards the `Range` header** and follows redirects (codeload 302s to a
    signed `objects.githubusercontent.com` URL), then streams the body back with
    an `Access-Control-Allow-Origin` header and the download-relevant headers
    exposed;
  - surfaces failures as CORS-enabled plain-text responses (`400`/`403`/`502`)
    rather than swallowing them, per the project's error-handling rule;
  - supports three opt-in access controls so it need not run as an open proxy:
    `ALLOWED_HOSTS` (which target hosts may be fetched, leading-dot subdomain
    match), `AUTH_KEY` (a shared secret required as `?key=`, the real "only me"
    lock, with the CORS preflight exempted), and `ALLOWED_ORIGINS` (which
    web-page origins may call it, scoping the CORS header to the caller).
- `cors-proxy/wrangler.toml` — the deploy config, with a commented `ALLOWED_HOSTS`
  example.
- `docs/cors-proxy.md` — the walkthrough (`wrangler login` → `wrangler deploy` →
  paste the URL into the loader), verification with `curl`, and the lock-down
  step. README's runtime-loader section links to it.

The proxy is entirely optional and out of the game's build: it is deployed by
hand with `wrangler`, not by CI, and the runtime already works without it for
local files.

## Consequences

- Users can self-host a reliable proxy in minutes and stop depending on a public
  service; the loader is unchanged (it already builds the right request).
- No new build or CI dependency — `cors-proxy/` is standalone JS deployed with
  `npx wrangler`, so nothing in the CMake/Emscripten/nix path is touched.
- **Open-proxy caveat.** Left unconfigured the Worker proxies any http(s) host
  for anyone, which is convenient but abusable if the URL is shared; the three
  access controls (`ALLOWED_HOSTS`, `AUTH_KEY`, `ALLOWED_ORIGINS`) are the
  documented mitigations, with a personal-use recipe (secret key + host
  allowlist) in `docs/cors-proxy.md`. All are off by default so the
  arbitrary-`.zip` use case keeps working out of the box.
- This is distinct from the Cloudflare **Pages** setup in `docs/deploy.md`
  (which publishes the game *page*); the two share a vendor but not a purpose,
  and the docs cross-reference to avoid confusion.
- Worker-runtime specifics (Range, redirects) are covered, but exotic hosts
  (auth-gated downloads, non-standard redirects) may still need per-case
  handling — the plain-text error responses make such failures visible.
