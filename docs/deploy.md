# Web deployment (GitHub Pages + Cloudflare Pages previews)

The `wasm` job in [`.github/workflows/build.yml`](../.github/workflows/build.yml)
cross-compiles the runtime to WebAssembly and uploads the page
(`index.html` + `index.js` + `index.wasm`, plus the `index.wasm.map` source
map) as the `wasm` build artifact. Two downstream jobs publish that artifact:

| Job | Trigger | Destination | URL |
| --- | --- | --- | --- |
| `deploy-pages` | push to `master` | GitHub Pages | `https://<owner>.github.io/<repo>/` |
| `preview-cloudflare` | `/preview` comment on a PR | Cloudflare Pages preview | commented on the PR |

Neither job rebuilds the wasm page — they reuse the exact bytes the `wasm` job
produced, so what the preview shows is what ships.

The build links without pthreads / SharedArrayBuffer, so the page needs no
`Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` headers and runs
on static hosts (like GitHub Pages) that cannot set them. Neither deployment
bakes a game in, so the page opens on its runtime loader — drop in a local
`.zip`, a `.zip` URL, or a `owner/repo` GitHub project to play.

## Changelog sub-page

Both `deploy-pages` and `preview-cloudflare` additionally check out
`CHANGELOG.md` and render it (via `scripts/render-changelog-page.bash`, which
shells out to `marked`) into a `changelog/` sub-page, linked from the game
page's header — so a `/preview` build shows the same changelog a merge would
publish.

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

## Publishing a preview: comment `/preview`

Previews are **on request, not automatic**. Comment

```
/preview
```

on a pull request and CI builds that PR's head commit and publishes it to
Cloudflare Pages, then edits a sticky comment on the PR with the URL. The
command comment gets a 👀 reaction as soon as the run starts. Comment
`/preview` again at any point to publish a fresh build of the latest head.

Previews cost a full wasm build each, and most PRs never need one, so nothing
is published until someone asks. Pushing new commits to a PR does **not**
refresh an existing preview — the previous URL keeps serving the build it was
made from until the next `/preview`.

Who may run it, and against what:

- Only comments from a repo **owner, org member or collaborator** are acted on;
  anyone else's `/preview` is ignored silently. `issue_comment` runs on the base
  repository with access to the secrets even for pull requests from forks, so
  this check is the security boundary — a maintainer typing `/preview` is what
  authorises a fork's code to be built and deployed.
- Fork pull requests therefore work, unlike the old automatic previews (a forked
  `pull_request` run cannot read the secrets; an `issue_comment` run can).
- Each PR deploys to the Cloudflare branch `pr-<number>`, so its preview URL is
  stable across repeated `/preview` runs and a fork branch that happens to be
  named `master` can never reach the production deployment.

Until the secrets are set, the `preview-cloudflare` job **skips the deploy and
still passes**, and comments on the PR to say the setup is missing — a missing
Cloudflare setup never blocks a PR, since the preview is an optional add-on to
the GitHub Pages deploy.

> Renaming the Cloudflare project? Update `--project-name` in the
> `preview-cloudflare` job to match.
