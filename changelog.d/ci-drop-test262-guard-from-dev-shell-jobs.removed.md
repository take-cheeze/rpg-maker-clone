- CI: the `Skip the quickjs test262 submodule` step is gone from the `build`,
  `ruby-checks` and `wasm` jobs. It existed only to keep nix's nested
  `.gitmodules` walk off tc39/test262, and those jobs stopped walking submodules
  when `flake.nix` dropped `self.submodules = true`. The `flake` job — the one
  that still asks, via `nix build '.?submodules=1#build'` — keeps it, and
  `scripts/skip-quickjs-test262.bash` stays for anyone running a
  `?submodules=1` command by hand.
