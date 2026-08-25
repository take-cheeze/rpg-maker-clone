#!/usr/bin/env bash

set -eu -o pipefail

# Render CHANGELOG.md into a static sub-page for the GitHub Pages deploy
# (`deploy-pages` job, build.yml), so the full changelog is browsable from the
# site instead of only living in the repo.
#
# `marked` runs via `npx` rather than a vendored dependency: it is only needed
# for this one render at deploy time, and the npm registry is already reached
# from CI the same way other scripts here fetch RTP zips and fonts.
#
# Usage: render-changelog-page.bash <CHANGELOG.md> <output dir>

md="$1"
out_dir="$2"
mkdir -p "$out_dir"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
npx --yes marked@12 --gfm -i "$md" -o "$body"

# Mirrors src/shell.html's dark palette so the sub-page reads as part of the
# same site rather than a bare unstyled document.
cat > "$out_dir/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Changelog — RPG Maker clone</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #14161a; --panel: #1e2127; --border: #333842;
    --fg: #e6e8eb; --muted: #9aa1ac; --accent: #4f8cff;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    background: var(--bg); color: var(--fg);
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    padding: 24px 16px 64px;
  }
  main {
    max-width: 720px; margin: 0 auto;
    background: var(--panel); border: 1px solid var(--border);
    border-radius: 10px; padding: 8px 28px 28px;
  }
  a { color: var(--accent); }
  h1, h2, h3 { border-bottom: 1px solid var(--border); padding-bottom: .3rem; }
  code { background: #12141a; padding: .1rem .35rem; border-radius: 4px; font-size: .9em; }
  pre { background: #12141a; padding: 12px; overflow-x: auto; border-radius: 6px; }
  pre code { background: none; padding: 0; }
  ul { padding-left: 1.3rem; }
  .back { display: inline-block; margin: 16px 0 0; color: var(--muted); font-size: 13px; text-decoration: none; }
  .back:hover { color: var(--accent); }
</style>
</head>
<body>
<a class="back" href="../">&larr; Back to the game</a>
<main>
HTML
cat "$body" >> "$out_dir/index.html"
cat >> "$out_dir/index.html" <<'HTML'
</main>
</body>
</html>
HTML

echo "changelog page: rendered $md -> $out_dir/index.html"
