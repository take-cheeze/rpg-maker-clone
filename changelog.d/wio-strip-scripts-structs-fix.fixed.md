- **wio:** `scripts/strip_wio_inline_helpers.rb` follows the record classes that
  replaced the rpg2k Structs (ADR 0215); every `MRUBY_TARGET=wio` build had
  failed in it since. A new `scripts/wio_strip_scripts_check.rb`, run in CI's
  `ruby-checks` job, applies the wio mrblib rewrites to the real sources so a
  source edit can no longer break them unnoticed.
