# Web deployment (GitHub Pages + Cloudflare Pages previews)

The `wasm` job in [`.github/workflows/build.yml`](../.github/workflows/build.yml)
cross-compiles the runtime to WebAssembly and uploads the page
(`index.html` + `index.js` + `index.wasm`, plus the `index.wasm.map` source
map) as the `wasm` build artifact. Two downstream jobs publish that artifact:

| Job | Trigger | Destination | URL |
| --- | --- | --- | --- |
| `deploy-pages` | push to `master` | GitHub Pages | `https://<owner>.github.io/<repo>/` |
| `preview-cloudflare` | pull request | Cloudflare Pages preview | commented on the PR |

Neither job rebuilds anything — they reuse the exact bytes the `wasm` job
produced, so what the preview shows is what ships.

The build links without pthreads / SharedArrayBuffer, so the page needs no
`Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` headers and runs
on static hosts (like GitHub Pages) that cannot set them. Neither deployment
bakes a game in, so the page opens on its runtime loader — drop in a local
`.zip`, a `.zip` URL, or a `owner/repo` GitHub project to play.

## One-time setup

### GitHub Pages

1. Repo **Settings → Pages → Build and deployment**.
2. Set **Source** to **GitHub Actions**.

That's all — `deploy-pages` uses `actions/deploy-pages`, which needs no branch
and no `gh-pages` branch. The workflow already grants the job the required
`pages: write` and `id-token: write` permissions.

### Cloudflare Pages previews

1. In the Cloudflare dashboard, **Workers & Pages → Create → Pages → Upload
   assets**, and create a project named **`rpg-maker-clone`** (this must match
   the `--project-name` in the `preview-cloudflare` job). Direct-Upload is the
   right type — we push assets from CI rather than letting Cloudflare build.
2. Create an API token (**My Profile → API Tokens**) with the
   **Account → Cloudflare Pages → Edit** permission.
3. Add two repository secrets under **Settings → Secrets and variables →
   Actions**:
   - `CLOUDFLARE_API_TOKEN` — the token from step 2.
   - `CLOUDFLARE_ACCOUNT_ID` — your account ID (shown in the dashboard URL and
     on any domain's overview page).

Once the secrets exist, every pull request from a branch in this repo gets a
fresh preview deployment and a sticky PR comment with its URL. Pull requests
from forks are skipped because forked runs cannot read the secrets.

Until the secrets are set, the `preview-cloudflare` job **skips the deploy and
still passes** (it logs a notice pointing here), so a missing Cloudflare setup
never blocks a PR — the preview is an optional add-on to the GitHub Pages
deploy.

> Renaming the Cloudflare project? Update `--project-name` in the
> `preview-cloudflare` job to match.
