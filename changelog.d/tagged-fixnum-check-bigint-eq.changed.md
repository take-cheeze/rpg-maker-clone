- **bc2cpp checks:** `tagged_fixnum_check.rb` compares `==`/`!=` for bigint receivers against `0` and `-0.0`
  again. It had skipped them because the pinned interpreter answered `2**70 == 0` as true; the mruby bump to
  `mruby-int-equal-bigint` fixed that, so interpreted and compiled runs agree on every pair.
