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

## Locking it down (optional but recommended)

As written the Worker will proxy **any** http(s) URL. That's fine for a private
URL you keep to yourself, but a public open proxy can be abused as an
anonymizing relay. To restrict it to the hosts the loader actually needs, set
the `ALLOWED_HOSTS` variable (comma-separated; a leading dot matches subdomains):

Either uncomment the `[vars]` block in
[`wrangler.toml`](../cors-proxy/wrangler.toml) and redeploy, or set it from the
CLI:

```sh
npx wrangler deploy --var ALLOWED_HOSTS:".github.com,codeload.github.com,objects.githubusercontent.com"
```

A blocked host gets a `403` with a clear message. GitHub archive downloads flow
through `codeload.github.com` and can redirect to `objects.githubusercontent.com`,
so include both; add any other zip hosts you use.

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
- **Errors** come back with CORS headers and a plain-text reason (`400` bad
  target, `403` blocked host, `502` upstream failure), so the loader shows a real
  message instead of an opaque network error.

## Notes and alternatives

- **Not the same as the Cloudflare *Pages* setup.** [`deploy.md`](deploy.md)
  covers publishing the game *page* (GitHub Pages + Cloudflare Pages previews).
  This proxy is a separate, optional Worker for *downloading projects at runtime*.
- **No proxy needed for local files.** *Open a local project* reads a `.zip`
  straight off disk with no network, so the proxy only matters for URL/GitHub
  loads.
- **Public proxies** like `https://corsproxy.io/?url=` work too (that's the
  field's placeholder), but they rate-limit and can disappear; your own Worker is
  more reliable and, with `ALLOWED_HOSTS`, not abusable.
