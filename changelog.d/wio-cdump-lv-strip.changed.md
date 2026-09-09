- **Wio Terminal: fixed `--remove-lv` (added in the previous change) to
  actually work.** It turned out to be a no-op for this build: mruby's own
  C-struct dumper (`src/cdump.c`, used because this build always passes
  `-S`) never checks the `MRB_DUMP_NO_LVAR` flag at all, unlike its binary
  `.mrb` dumper (`src/dump.c`), which does -- a real gap in mruby's own
  toolchain. Since `3rd/mruby` is the real upstream repo (not a fork this
  project can push a patch to), `build_config.rb` now wraps `conf.mrbc`'s
  own `run` method to strip the same data out of the generated C source
  afterward. Real relink: 43,312 more bytes of flash recovered, no RAM
  cost. See ADR 118.
