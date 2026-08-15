- **Saving a game no longer crashes the `.lsd` export.** ADR 0018 added
  `LCF.utf8_to_cp932` to `mruby-lcf/mrblib/lcf.rb` (`LCF.encode`'s `:string`
  branch) as the write-side mirror of the native `LCF.cp932_to_utf8` reader,
  but the native uni-algo encoder itself was never added to
  `mruby-lcf/src/lcf.cxx` — only the CRuby test harnesses got a stand-in. The
  real mruby build therefore had no `LCF.utf8_to_cp932` at all, so any save
  with a `:string` field (actor/hero names, the BGM name in the extended
  system fields) raised `undefined method 'utf8_to_cp932' for Module` and
  aborted the `.lsd` export. `utf8_to_cp932` is now implemented in
  `mruby-lcf/src/lcf.cxx`, built from the same `cp932_table` `cp932_to_utf8`
  already uses (reversed and re-sorted by Unicode code point instead of by
  CP932 code), and registered alongside it in `mrb_mruby_lcf_gem_init`.
