- Fixed a real field-access collision bug in `mruby-lcf`: `LCF::Array1D`/
  `LCF::Sections`/`LCF::File` resolved dot-syntax field access (e.g.
  `db.system`) via `method_missing`, which silently loses to any real
  method of the same name already reachable on the object (`db.system`
  resolving to `Kernel#system` instead of the LCF `system` field, per
  AGENTS.md's own documented workaround). Added real `Symbol`-accepting
  `[]`/`[]=`/`key?` (`db[:system]`, immune to the collision) and migrated
  every real engine call site found by dynamically instrumenting
  `method_missing` and running the full CRuby test suite (158 sites,
  mostly `mruby-rpg2k/mrblib/game/lsd_io.rb`'s save-file loader/writer).
  `method_missing` stays as a safety net for any not-yet-migrated call
  site outside current test coverage. See docs/adr/0138.
