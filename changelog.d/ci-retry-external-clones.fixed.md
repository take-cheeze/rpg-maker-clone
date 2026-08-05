- CI: the external test-bed / corescript **clones are retried** instead of
  failing a job outright. `scripts/git-clone-retry.bash` wraps `git clone` with
  four attempts and an exponential backoff, clearing the partial directory a
  failed attempt leaves behind so the retry actually re-fetches rather than
  dying on "already exists and is not an empty directory". The five scripts that
  clone from an external host use it (`download-opengame-xp`,
  `download-mv-corescript`, `download-mz-corescript`, `download-lunatic-core`,
  `download-mtf-meido-action`). These run as `background: true` steps, so one
  hiccup at the far end used to take a whole job down *before the compiler had
  run at all* — it reads as a build failure and is not one; two different hosts
  were seen doing it in the same evening. `wget` already retries on its own
  (20 attempts by default), which is why only the clones needed this. Same shape
  as `scripts/nix-develop.bash`: recover from a known transient failure where it
  happens, rather than weakening the CI gate around it.
