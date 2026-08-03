- Self-hostable **CORS proxy** for the web loader: a ready-to-deploy Cloudflare
  Worker in `cors-proxy/` (`worker.js` + `wrangler.toml`) that the loader's *CORS
  proxy prefix* field can point at, so GitHub repos and arbitrary `.zip` URLs
  load without depending on a public proxy service. The Worker accepts both
  prefix styles the loader builds (`?url=<encoded>` and `/<raw url>`), handles
  the CORS preflight, forwards `Range` requests and follows redirects, and takes
  three opt-in access controls to avoid running as an open proxy: `ALLOWED_HOSTS`
  (target hosts), `AUTH_KEY` (a shared secret required as `?key=` — the "only me"
  lock), and `ALLOWED_ORIGINS` (which web-page origins may call it). Deploy and
  personal-use lock-down walkthrough in `docs/cors-proxy.md`; rationale in
  `docs/adr/0010-cors-proxy-cloudflare-worker.md`.
