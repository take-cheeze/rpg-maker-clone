- **CORS proxy R2 cache** (optional): the Cloudflare Worker in `cors-proxy/`
  can now bind an R2 bucket (`ARCHIVE_CACHE`) to cache fetched game archives,
  so a repeat load — by anyone, from any browser — is served from Cloudflare's
  edge instead of re-fetching from the origin host. Off by default; entries
  expire after `CACHE_TTL_SECONDS` (default 1 hour, since a GitHub branch
  archive's URL doesn't change even though its contents can) and
  `CACHE_MAX_BYTES` caps what gets cached. Setup in `docs/cors-proxy.md`;
  rationale in `docs/adr/0042-cors-proxy-r2-cache.md`.
