- The Nix flake is slimmer: `nixpkgs.lib.genAttrs` replaces the hand-rolled
  `eachDefaultSystem` fold, the platform-conditional dependency lists use
  `lib.optionals` under a single `with pkgs`, and the dev shell no longer
  carries the unused Haskell toolchain (`ghc`, `cabal-install`) or `python3`
  (the tooling scripts that call `python3` now take it from the host).
