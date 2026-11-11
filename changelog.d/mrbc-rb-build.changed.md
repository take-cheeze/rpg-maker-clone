- **bc2cpp** compiles its Ruby sources with nfcxx's own emitter (`bc2cpp/tools/mrbc_rb`) by default, so the compiled-gem
  build (`mruby-core-compiled`, `mruby-lcf-compiled`) no longer waits for the `mrbc` binary
  (`BC2CPP_USE_BUILD_MRBC=1` hands it over as a fallback). `MRUBY_MRBC_RB=1` also builds mruby's own gems with the same
  command in place of the C `mrbc`. `3rd/nfcxx` is bumped for it.
