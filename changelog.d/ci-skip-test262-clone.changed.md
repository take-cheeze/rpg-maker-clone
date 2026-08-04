- CI no longer clones `tc39/test262`. Every nix job (`build`, `wasm`, `flake`)
  fetches this flake with `self.submodules = true`, which walks quickjs-ng's
  nested `test262` entry; the `flake` job used to materialize that submodule
  (the whole conformance suite, which git itself skips via `update = none`)
  just to keep the walk happy. `scripts/skip-quickjs-test262.bash` now
  deregisters the entry from the quickjs checkout instead, and each nix job
  runs it after checkout. Set `CLONE_TEST262=1` to opt out.
