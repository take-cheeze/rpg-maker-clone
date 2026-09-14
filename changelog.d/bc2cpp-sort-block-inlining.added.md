- `tools/bc2cpp/bc2cpp.rb` now compiles `sort_by`/`uniq` key blocks
  via a Schwartzian transform in ordinary compiled operations (key
  extraction through the inlined block body, index-decorated insertion
  sort on `(key, index)` via public `mrb_cmp`, undecorate), plus a
  chained-receiver rule letting `select`/`reject`/`map` call results
  prove Array-ness downstream. Comparator `sort` blocks are recognized
  and honestly rejected (no loop to inline -- the VM drives them
  natively). Stability is structural (CRuby `sort_by` is stable,
  mruby's sort is not; turn-order ties depend on it). +0 methods this
  round: every real site is blocked one level deeper (key bodies
  calling uncompiled methods, unproven chain roots) -- the capability
  is built and proven, unlocking is receiver/callee work. Verified
  against a runtime harness (8 cases incl. stable ties) plus
  end-to-end regen with zero regressions. See docs/adr/0156.
