- CI no longer clones `tc39/test262`. The flake job used to materialize
  quickjs-ng's nested `test262` submodule (which git itself skips, `update =
  none`) just so `nix build` with `self.submodules = true` would not trip over
  the missing directory; it now drops the entry from the quickjs working tree
  instead. Set the `CLONE_TEST262` repository variable to `1` to fetch the
  conformance suite anyway.
