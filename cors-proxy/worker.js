// CORS proxy for the rpg-maker-clone web loader.
//
// The loader (src/shell.html) fetches an RPG Maker project zip from a
// cross-origin host (GitHub's codeload archive, or an arbitrary .zip URL).
// Browsers block those reads unless the host sends CORS headers, and GitHub
// does not, so the loader prepends a proxy prefix to the target URL. This
// Worker is that proxy: it fetches the target server-side (where the
// same-origin policy does not apply) and re-serves the bytes with an
// `Access-Control-Allow-Origin` header so the browser will accept them.
//
// It accepts both prefix styles the loader can build:
//   - query style  https://<worker>/?url=<encoded target>
//   - path style   https://<worker>/<raw target>
//
// Deploy with `wrangler deploy` (see docs/cors-proxy.md). Three optional
// vars restrict use so this isn't an open proxy (all unset => open):
//   - ALLOWED_HOSTS   — which target hosts may be fetched (comma-separated;
//                       a leading dot matches subdomains).
//   - AUTH_KEY        — a shared secret; requests must carry ?key=<secret>.
//                       This is the real "only me" lock. Requires the query
//                       prefix style (?key=…&url=). Preflight is exempt.
//   - ALLOWED_ORIGINS — which web-page origins may call it (comma-separated,
//                       exact scheme+host, e.g. https://you.github.io). The
//                       CORS header is then scoped to the caller's origin.
//
// An optional R2 bucket caches fetched archives so repeat loads (by anyone,
// from any browser) skip the upstream fetch entirely (all unset => no cache):
//   - ARCHIVE_CACHE     — R2 bucket binding (see wrangler.toml). Unbound =>
//                         every request proxies straight through, unchanged.
//   - CACHE_TTL_SECONDS — how long a cached entry stays fresh before being
//                         treated as a miss and re-fetched (default 3600 = 1
//                         hour). A target URL's bytes can change server-side
//                         (e.g. a GitHub branch archive tracks new commits),
//                         so entries are revalidated rather than kept forever.
//   - CACHE_MAX_BYTES   — skip caching (but still proxy normally) a response
//                         whose Content-Length exceeds this, to cap R2 usage.
//                         Unset => no limit.

const DEFAULT_CACHE_TTL_SECONDS = 3600;

function corsHeaders(origin) {
  const h = {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': 'Range, Content-Type',
    // Let the browser read the headers a downloader/streamer cares about.
    'Access-Control-Expose-Headers':
      'Content-Length, Content-Type, Content-Range, Accept-Ranges, ETag, Last-Modified, X-Proxy-Cache',
    'Access-Control-Max-Age': '86400',
  };
  // When the header is scoped to a specific origin, caches must key on it.
  if (origin !== '*') h['Vary'] = 'Origin';
  return h;
}

function withCors(headers, origin) {
  const h = new Headers(headers);
  for (const [k, v] of Object.entries(corsHeaders(origin))) h.set(k, v);
  return h;
}

// A short, CORS-enabled error so the browser sees a real message instead of an
// opaque network failure.
function fail(status, message, origin) {
  return new Response(message + '\n', {
    status,
    headers: withCors({ 'Content-Type': 'text/plain; charset=utf-8' }, origin || '*'),
  });
}

// Decide the Access-Control-Allow-Origin value for this request. Returns '*'
// when no origin allowlist is configured, the caller's origin when it is on the
// list, or null when the list is set and the caller isn't on it (=> blocked).
function resolveOrigin(request, env) {
  const allowed = ((env && env.ALLOWED_ORIGINS) || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (allowed.length === 0) return '*';
  const origin = request.headers.get('Origin') || '';
  return origin && allowed.includes(origin) ? origin : null;
}

// Pull the target URL out of the incoming request, supporting both prefix
// styles the loader builds.
function targetFrom(request) {
  const url = new URL(request.url);

  // Query style: ?url=<encoded>. URLSearchParams has already decoded it.
  const q = url.searchParams.get('url');
  if (q) return q;

  // Path style: everything after the leading "/", raw. The loader appends the
  // target verbatim, so "https://host/path?a=b" arrives as pathname "/https://
  // host/path" plus search "?a=b"; stitch them back together.
  const rest = url.pathname.slice(1) + url.search + url.hash;
  if (rest) return decodeURIComponent(rest);

  return '';
}

// Optional host allowlist. Set ALLOWED_HOSTS to a comma-separated list of
// hostnames; a leading dot means "this host and any subdomain" (".github.com"
// matches "codeload.github.com"). Unset => allow everything.
function hostAllowed(hostname, allowed) {
  if (!allowed) return true;
  const list = allowed
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  if (list.length === 0) return true;
  const host = hostname.toLowerCase();
  return list.some((entry) =>
    entry.startsWith('.') ? host === entry.slice(1) || host.endsWith(entry) : host === entry,
  );
}

// SHA-256 of the target URL, hex-encoded, as the R2 object key. Keying on the
// resolved target (not the caller's key/origin) means every caller shares one
// cache entry per resource, and both loader prefix styles hit the same entry.
async function cacheKeyFor(target) {
  const data = new TextEncoder().encode(target.toString());
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function cacheTtlSeconds(env) {
  const raw = env && env.CACHE_TTL_SECONDS;
  const n = raw === undefined || raw === '' ? NaN : Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_CACHE_TTL_SECONDS;
}

function isFresh(cachedAtIso, ttlSeconds) {
  if (!cachedAtIso) return false;
  const cachedAt = Date.parse(cachedAtIso);
  if (Number.isNaN(cachedAt)) return false;
  return Date.now() - cachedAt < ttlSeconds * 1000;
}

// Parses a single `Range: bytes=<start>-<end>` header into R2's range shape.
// Multi-range and malformed headers fall back to "no range" (full object),
// same as how a plain HTTP server ignores a Range it can't honour.
function parseRange(header) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;
  if (m[1] === '') {
    const suffix = parseInt(m[2], 10);
    return Number.isFinite(suffix) && suffix > 0 ? { suffix } : null;
  }
  const offset = parseInt(m[1], 10);
  if (!Number.isFinite(offset) || offset < 0) return null;
  if (m[2] === '') return { offset };
  const end = parseInt(m[2], 10);
  return Number.isFinite(end) && end >= offset ? { offset, length: end - offset + 1 } : null;
}

function r2ContentHeaders(obj) {
  const headers = new Headers();
  if (obj.httpMetadata && obj.httpMetadata.contentType) {
    headers.set('Content-Type', obj.httpMetadata.contentType);
  }
  headers.set('Accept-Ranges', 'bytes');
  if (obj.httpEtag) headers.set('ETag', obj.httpEtag);
  if (obj.uploaded) headers.set('Last-Modified', obj.uploaded.toUTCString());
  return headers;
}

export default {
  async fetch(request, env, ctx) {
    // Preflight — the browser sends this before a cross-origin fetch with
    // non-simple headers (e.g. Range). It carries no credentials, so it is
    // exempt from the AUTH_KEY check; the origin check still applies.
    const acao = resolveOrigin(request, env);
    if (request.method === 'OPTIONS') {
      if (acao === null) return fail(403, 'Origin not allowed.', '*');
      return new Response(null, { status: 204, headers: withCors({}, acao) });
    }

    if (acao === null) return fail(403, 'Origin not allowed.', '*');

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return fail(405, 'Only GET, HEAD and OPTIONS are supported.', acao);
    }

    // Shared-secret gate. When AUTH_KEY is set, every GET/HEAD must carry a
    // matching ?key=<secret> (add it to the proxy prefix: ...?key=SECRET&url=).
    if (env && env.AUTH_KEY) {
      const key = new URL(request.url).searchParams.get('key');
      if (key !== env.AUTH_KEY) {
        return fail(403, 'Missing or invalid key.', acao);
      }
    }

    const raw = targetFrom(request);
    if (!raw) {
      return fail(
        400,
        'No target URL. Use ?url=<encoded-url> or append the URL to the path: /<url>.',
        acao,
      );
    }

    let target;
    try {
      target = new URL(raw);
    } catch {
      return fail(400, 'Malformed target URL: ' + raw, acao);
    }
    if (target.protocol !== 'http:' && target.protocol !== 'https:') {
      return fail(400, 'Only http(s) targets are allowed.', acao);
    }
    if (!hostAllowed(target.hostname, env && env.ALLOWED_HOSTS)) {
      return fail(403, 'Host not allowed by this proxy: ' + target.hostname, acao);
    }

    const cache = env && env.ARCHIVE_CACHE;
    const cacheKey = cache ? await cacheKeyFor(target) : null;
    const requestRange = request.headers.get('Range');

    // Cache read. A single head() decides hit/miss (and freshness) up front;
    // the body is only fetched from R2 once we know we're serving it.
    let cacheHit = null;
    if (cache) {
      try {
        const head = await cache.head(cacheKey);
        if (head && isFresh(head.customMetadata && head.customMetadata.cachedAt, cacheTtlSeconds(env))) {
          cacheHit = head;
        }
      } catch (e) {
        console.error('cache lookup failed for ' + target + ': ' + e.message);
      }
    }

    if (cacheHit && request.method === 'HEAD') {
      const headers = r2ContentHeaders(cacheHit);
      headers.set('Content-Length', String(cacheHit.size));
      headers.set('X-Proxy-Cache', 'HIT');
      return new Response(null, { status: 200, headers: withCors(headers, acao) });
    }

    if (cacheHit && request.method === 'GET') {
      try {
        const r2Range = parseRange(requestRange);
        const obj = await cache.get(cacheKey, r2Range ? { range: r2Range } : undefined);
        if (obj) {
          const headers = r2ContentHeaders(obj);
          headers.set('X-Proxy-Cache', 'HIT');
          if (obj.range) {
            const { offset, length } = obj.range;
            headers.set('Content-Length', String(length));
            headers.set('Content-Range', `bytes ${offset}-${offset + length - 1}/${obj.size}`);
            return new Response(obj.body, { status: 206, headers: withCors(headers, acao) });
          }
          headers.set('Content-Length', String(obj.size));
          return new Response(obj.body, { status: 200, headers: withCors(headers, acao) });
        }
      } catch (e) {
        console.error('cache read failed for ' + target + ': ' + e.message);
      }
    }

    // Forward the fetch server-side. Pass the Range header through so the
    // browser can resume/stream partial downloads, and follow redirects
    // (GitHub's codeload endpoint 302s to a signed URL).
    const forward = new Headers();
    if (requestRange) forward.set('Range', requestRange);
    forward.set('Accept', request.headers.get('Accept') || '*/*');

    let upstream;
    try {
      upstream = await fetch(target.toString(), {
        method: request.method,
        headers: forward,
        redirect: 'follow',
        // Cloudflare caches Worker fetch() subrequests at the edge (keyed by
        // URL, shared across every caller hitting the same origin) according
        // to standard HTTP cache rules — independent of, and in addition to,
        // the R2 cache above. A transient upstream error can get stuck there
        // and get served back for a long time regardless of what the origin
        // returns afterwards. Opt out: the R2 cache already does explicit,
        // TTL-checked caching, so this layer only adds an invisible failure
        // mode on top of it.
        cf: { cacheTtl: 0, cacheEverything: false },
      });
    } catch (e) {
      return fail(502, 'Upstream fetch failed for ' + target + ': ' + e.message, acao);
    }

    // Populate the cache from a plain (non-Range) GET that came back whole —
    // a Range request or partial status is proxied through without touching
    // R2, so a cache entry is always the complete object.
    let responseBody = upstream.body;
    let cacheStatus = cache ? 'BYPASS' : null;
    if (cache && request.method === 'GET' && !requestRange && upstream.status === 200 && upstream.body) {
      const maxBytes = env.CACHE_MAX_BYTES ? Number(env.CACHE_MAX_BYTES) : null;
      const contentLength = upstream.headers.get('Content-Length');
      const tooBig = maxBytes && contentLength && Number(contentLength) > maxBytes;
      if (!tooBig) {
        const [clientBody, cacheBody] = upstream.body.tee();
        responseBody = clientBody;
        cacheStatus = 'MISS';
        ctx.waitUntil(
          cache
            .put(cacheKey, cacheBody, {
              httpMetadata: { contentType: upstream.headers.get('Content-Type') || undefined },
              customMetadata: { sourceUrl: target.toString(), cachedAt: new Date().toISOString() },
            })
            .catch((e) => console.error('cache put failed for ' + target + ': ' + e.message)),
        );
      }
    }

    // Re-serve the upstream response with CORS headers, streaming the body.
    const headers = withCors(upstream.headers, acao);
    if (cacheStatus) headers.set('X-Proxy-Cache', cacheStatus);
    return new Response(responseBody, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers,
    });
  },
};
