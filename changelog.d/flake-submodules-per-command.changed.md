- `flake.nix` no longer declares `self.submodules = true`. It made *every* `nix`
  call fetch all twelve submodules with `refs/*:refs/*` — a full-history fetch
  per submodule, GitHub's `refs/pull/*` heads included, lvgl alone accounting for
  ~760 MiB of them — even though only `packages.build` reads those sources. The
  three CI jobs that enter the dev shell (`build`, `ruby-checks`, `wasm`) compile
  the workspace checkout, never nix's copy of it, so they paid the whole walk for
  nothing. The one job that needs the sources now asks per command:
  `nix build '.?submodules=1#build'`. `scripts/skip-quickjs-test262.bash` stays
  in the dev-shell jobs as a cheap guard, but only the `flake` job still triggers
  the nested-`.gitmodules` walk it exists for.
