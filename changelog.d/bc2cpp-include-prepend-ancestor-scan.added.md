- **bc2cpp** now scans the whole closed world for `include`/`prepend`
  (`build_registry`, `ANCESTOR_MIXINS_SUPPORT`) and gates `super` compilation on
  a re-derived `super_reaches_superclass?` guard instead of a hand-vetted
  "no intervening include" assertion — a `super` into a declared superclass now
  compiles only while the scan proves the ancestor chain is clean. Real-project
  output is unchanged (every compiled `super` owner has no plain `include`); the
  new guard declines on any unrecognized mixin or plain include. Prerequisite
  for general `super`/zsuper support (ADR 0158); covered by
  `scripts/bc2cpp_include_ancestor_check.rb`.
