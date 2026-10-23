- **bc2cpp** memoizes the per-file native owner map scan (`NativeOwnerMap.build`) in the scan cache, so a warm
  generator run no longer re-reads the native sources for it. The generated output is unchanged.
