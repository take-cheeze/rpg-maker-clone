- **bc2cpp type check**: the native entry's constructor argument (the Array the
  wio and browser entries pass to each maker's `initialize`) now seeds the
  call-graph argument types. `BC2CPP_ENTRY_SEEDS=0` turns it off. Reporting
  only; compiled output is unchanged. See ADR 0519.
