- **bc2cpp does Fixnum arithmetic on the boxed word.** Under word boxing with
  an `mrb_int` as wide as the word (native, Emscripten, PSP, Wio), the Fixnum
  arms of `+ - *` (and `+ k`/`- k`), `& | ^` and the compares test both tags
  with one mask and operate on the tagged words. One overflow builtin replaces
  the unbox, overflow, `FIXABLE` and rebox steps. Other boxings keep the old
  form. `+ - *` on a heap Integer (outside the Fixnum range but within
  `mrb_int`) no longer sends the operator, which matches the VM in a world that
  reopens `Integer#+`. See `docs/bc2cpp-tagged-fixnum.md`; checked by
  `scripts/bc2cpp/tagged_fixnum_check.rb`.
