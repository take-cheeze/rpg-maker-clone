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

function corsHeaders(origin) {
  const h = {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': 'Range, Content-Type',
    // Let the browser read the headers a downloader/streamer cares about.
    'Access-Control-Expose-Headers':
      'Content-Length, Content-Type, Content-Range, Accept-Ranges, ETag, Last-Modified',
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

export default {
  async fetch(request, env) {
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

    // Forward the fetch server-side. Pass the Range header through so the
    // browser can resume/stream partial downloads, and follow redirects
    // (GitHub's codeload endpoint 302s to a signed URL).
    const forward = new Headers();
    const range = request.headers.get('Range');
    if (range) forward.set('Range', range);
    forward.set('Accept', request.headers.get('Accept') || '*/*');

    let upstream;
    try {
      upstream = await fetch(target.toString(), {
        method: request.method,
        headers: forward,
        redirect: 'follow',
      });
    } catch (e) {
      return fail(502, 'Upstream fetch failed for ' + target + ': ' + e.message, acao);
    }

    // Re-serve the upstream response with CORS headers, streaming the body.
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: withCors(upstream.headers, acao),
    });
  },
};
