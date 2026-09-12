- `tools/bc2cpp/bc2cpp.rb` now compiles real `begin...rescue...end`
  constructs (`EXCEPT`/`RESCUE`/`RAISEIF`), a permanent gap since bc2cpp's
  own first version (docs/adr/0139). Scoped to the one shape every real
  rescue clause in `mruby-rpg2k/mrblib` actually uses (a single rescue
  class, no `retry`, no `ensure`) via `mrb_protect_error` -- the same real
  core mruby primitive `GETCONST`'s own owner-scope lookup already relies
  on. Unlocks 93 real methods across the three `*-compiled` gems (2 in
  `mruby-rgss-compiled`, 91 in `mruby-rpg2k-compiled`), plus their own
  cascading call-site devirtualization (e.g. `RPG2k::Scene::Base#
  play_system_se`'s own ~152 call sites). Verified against a real runtime
  harness (success/rescue-match/re-raise/guard-clause paths, all four
  matching real Ruby semantics) as well as the usual real end-to-end
  regen + `register.cxx` compile. See docs/adr/0145.
