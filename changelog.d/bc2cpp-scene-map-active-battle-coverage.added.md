- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `RPG2k::Scene::Map#active_battle` in `mruby-rpg2k-compiled` -- a bare
  `@battle` reader, `public :active_battle`, right next to the already-
  registered `#headless_battle`/`#close_battle`. A real, previously-missed
  registration gap: it compiled clean (0 arguments, no super/block/rescue)
  but was never wired up in `mruby-rpg2k-compiled/src/register.cxx`, and
  the round that documented every other `public :name` reopening on this
  class simply missed it too -- found this round by diffing the real
  whole-program `== compiled entry points ==` listing's own entry names
  against every name actually referenced across all three compiled gems'
  `register.cxx`. Its one real call site (`scene.active_battle` in
  `mruby-rpg2k/mrblib/main.rb`, guarded by a preceding
  `scene.respond_to?(:active_battle)` check) was already safe either way,
  since `active_battle` is MONO and that call already devirtualized
  straight into the real `_impl` regardless of registration -- this fix
  only affects non-devirtualized dispatch (an uncompiled caller, `#send`,
  ...), which stayed on the interpreter until now. The same diff's other
  hit, `RGSS::Graphics.singleton#brightness_sprite`, is not a gap: it is
  genuinely `private`, mruby's public API has no "private class method"
  registration entry point at all, and its own one real call site already
  devirtualizes directly -- already correctly documented as a deliberate
  exclusion in `mruby-rgss-compiled/src/register.cxx`.
