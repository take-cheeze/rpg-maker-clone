# cors-proxy

A tiny Cloudflare Worker that lets the web loader download RPG Maker projects
from cross-origin hosts (GitHub archives, arbitrary `.zip` URLs) that don't send
CORS headers.

- [`worker.js`](worker.js) — the proxy. Accepts both `?url=<encoded>` (query)
  and `/<raw url>` (path) prefix styles the loader builds, forwards the fetch
  server-side, and re-serves the bytes with `Access-Control-Allow-Origin: *`.
- [`wrangler.toml`](wrangler.toml) — Worker config; optional `ALLOWED_HOSTS`
  var to avoid running an open proxy.

## Deploy

```sh
npx wrangler login
npx wrangler deploy
```

Then paste the printed `*.workers.dev` URL into the loader's **CORS proxy
prefix** field (append `/?url=`).

Full walkthrough, verification, and lock-down steps:
[`../docs/cors-proxy.md`](../docs/cors-proxy.md).
