- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 25 of
  `Game::Picture`'s 26 real bytecode methods (`mruby-rpg2k-compiled`, a
  companion to `mruby-lcf-compiled`) -- everything but `#initialize`
  (optional arguments). Extending to a second real class also hardened
  `tools/bc2cpp/bc2cpp.rb` itself: it now tracks real Ruby method
  visibility (a private method compiled but registered as public would
  have been a silent behavior change) and refuses to embed an instance
  variable as a struct field unless the owning class's own `#initialize`
  is itself compilable (the only place the struct actually gets
  allocated). See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
