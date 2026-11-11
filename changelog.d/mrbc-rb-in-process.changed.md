- `MRUBY_MRBC_RB=1` builds mruby's own gems with nfcxx's `mrbc` emitter **in-process**: `build_config.rb` loads
  `3rd/nfcxx/bc2cpp/tools/mrbc_rb/mruby_build`, so the rake process compiles every mrblib and test file itself instead of
  starting `mrbc_rb` once per file (one Prism load per build). `3rd/nfcxx` is bumped for it.
