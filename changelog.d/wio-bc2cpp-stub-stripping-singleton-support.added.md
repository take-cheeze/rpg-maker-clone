- **`strip_wio_bc2cpp_stubs.rb` (wio's bc2cpp-covered-bytecode stripper,
  docs/adr/0144) now supports `.singleton` owners** — both a bare `def
  self.foo` (an AST `DEFS` node) and a `class << self; def foo; end; end`
  block (an AST `SCLASS` node wrapping ordinary `DEFN`s), matching
  bc2cpp.rb's own `"Owner.singleton"` pseudo-owner convention exactly and
  gated on a real `:SELF`-receiver check so a `def SomeOtherConst.foo` is
  never mistaken for one. Verified in isolation (a hand-built fixture plus
  TSV) before touching any real source file. Scaled to two real
  `.singleton` owners already covered by `mruby-rgss-compiled`
  (`RGSS::Audio.singleton`'s 13 methods, `RGSS::ErrorReport.singleton`'s 6)
  plus one more plain-instance owner (`RGSS::Window`'s 12), each re-checked
  for the same gem-init-ordering correctness question docs/adr/0144's
  original round required. A real, from-scratch `wio_rgss_boot` A/B found
  a further **-2,216 bytes flash / -128 bytes RAM**, on top of the
  original round's own -696/-64 for `RGSS::Sprite` — see
  `docs/adr/0144-wio-bc2cpp-covered-bytecode-stripping.md`'s own dated
  follow-up section for the full writeup, including a real, honestly-
  flagged aside about two other `.singleton` owners' own native
  runtime call-backs (not gem-init-time ones) that a future round scaling
  further would still need to check for itself.
