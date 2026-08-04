- **Cloudflare Pages previews are now on request.** The `preview-cloudflare` CI
  job no longer runs for every pull request; comment `/preview` on a PR and CI
  builds that PR's head and posts the preview URL back on it. Only owner /
  member / collaborator comments are honoured, which — because `issue_comment`
  runs on the base repo — also makes previews work for pull requests from forks,
  which the automatic `pull_request` runs could never do. See `docs/deploy.md`.
