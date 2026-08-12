#!/usr/bin/env bash

# Rewrite a URL to go through the optional CI CORS proxy, so a download that
# lands in its R2 cache (cors-proxy/worker.js, docs/cors-proxy.md) is served
# from Cloudflare's edge on a repeat run instead of re-hitting the origin host.
#
# Source this and call `proxied_url <url>`.
#
# With CORS_PROXY_URL unset (the default), it returns the url unchanged: this
# is a pure opt-in behind a repository secret, so no fork or local run is
# affected. And even when set, it rarely does anything -- the "cache test
# game" actions/cache step above each download step in build.yml restores
# previously-fetched files first, and the download scripts skip work already
# on disk, so most runs never call this at all. It only matters as a fallback
# on an actions/cache miss (a new runner, an evicted cache, a changed download
# script), where it protects small third-party hosts (til.sakura.ne.jp,
# dl.fgamearchives.com) from CI re-hitting them on every cold cache instead of
# the R2 cache absorbing it.
#
# Builds the same prefix shape the web loader does (src/shell.html's
# fetchZip()) and the Worker accepts: a prefix ending in ?, & or = gets the url
# appended url-encoded (query style, the one to use when the prefix carries
# ?key=...&url= -- see docs/cors-proxy.md's AUTH_KEY); anything else gets the
# raw url appended after a /.
#
# CORS_PROXY_URL must come from a GitHub Actions *secret* (`${{
# secrets.CORS_PROXY_URL }}`), not a `vars.*` variable, whenever it carries an
# AUTH_KEY. Callers run under `set -x`, so the resolved URL -- prefix and all
# -- lands verbatim in the step's trace output; only sourcing it from
# `secrets.*` gets it registered for GitHub's automatic log masking, which is
# the only thing standing between a keyed prefix and a public CI log.
proxied_url() {
    local url="$1" prefix="${CORS_PROXY_URL:-}"
    if [ -z "$prefix" ]; then
        printf '%s\n' "$url"
        return
    fi
    case "$prefix" in
    *\? | *\& | *=)
        printf '%s%s\n' "$prefix" \
            "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
        ;;
    *)
        printf '%s/%s\n' "${prefix%/}" "$url"
        ;;
    esac
}
