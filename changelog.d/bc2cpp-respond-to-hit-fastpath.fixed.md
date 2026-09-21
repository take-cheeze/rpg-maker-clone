- **bc2cpp** answers successful one-argument `respond_to?` checks through
  mruby's public lookup APIs and preserves Ruby dispatch for missing methods,
  including custom `respond_to_missing?` hooks.
