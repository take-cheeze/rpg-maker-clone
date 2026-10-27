- **bc2cpp**: the numeric proofs now read what native code defines on nil from each registration's owner, along
  nil's lookup path and the modules a native include adds to it
  ([NIL_NATIVE_ANSWERS](docs/bc2cpp-nil-native-answers.md)). The old scan took every operator in any file that
  mentions `nil_class`, so `mruby-rational`'s `nil.to_r` made `+`, `-`, `*` and `/` nil operators. It also left out
  `Kernel#<=>`. A may-be-nil `@x += 1` now proves its ivar: in optcarrot that covers `PPU#@hclk`, `@scanline`,
  `@sp_buffered`, `@sp_index` and four APU ivars. The Ruby half also checks modules included into nil's
  ancestors and foreign definers. Check: `scripts/bc2cpp/nil_native_answers_check.rb`.
