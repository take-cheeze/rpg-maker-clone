- **CORS proxy**: the Worker's upstream `fetch()` now opts out of Cloudflare's
  edge cache (`cf: { cacheTtl: 0, cacheEverything: false }`). That cache is
  keyed by URL and shared across every caller hitting the same origin,
  independent of the proxy's own R2 cache — a transient upstream error (e.g. a
  404 from `cdn.tkool.jp`) could get stuck there and be served back to every
  RTP download for a long time afterwards, regardless of what the origin
  returns now. The R2 cache above already does explicit, TTL-checked caching,
  so this extra layer only added an invisible failure mode.
