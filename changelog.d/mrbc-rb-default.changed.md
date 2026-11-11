- **Build:** mruby's own gem build compiles every mrblib with nfcxx's Ruby `mrbc` emitter **by default**, in the rake
  process and without waiting for a C `mrbc` build (about 20 s of a 120 s host build on 4 cores). `MRUBY_MRBC_RB=0` opts
  out. `build_config.rb` turns it off by itself, with a one-line notice, when `3rd/nfcxx` is not checked out or Prism
  (1.0 or newer) cannot be loaded by rake's Ruby, and for the bc2cpp closed-world build. A file the emitter does not
  cover (mrbtest's `test/t/*.rb`) builds the C `mrbc` on demand in `<build>/mrbc-fallback`; `MRBC_FALLBACK` still names
  another one. `rake host_mrbc` (`mruby_host_mrbc`) builds the C `mrbc` as before; a plain `rake` no longer leaves
  `<build>/host/mrbc/bin/mrbc`. `3rd/nfcxx` is bumped for it.
