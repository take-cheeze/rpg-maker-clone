- Fixed a build-system bug in the opt-in (`RPGMAKER_BC2CPP=1`) AOT
  compiler's own build integration: `mruby-rpg2k-compiled`'s,
  `mruby-lcf-compiled`'s, and `mruby-rgss-compiled`'s `mrbgem.rake` each
  declared their generated whole-program C++ file as depending on
  `bc2cpp.rb` and the closed-world `.rb` sources, but never on
  `tools/bc2cpp/compiled_gems.rb` -- the file that actually selects which
  classes get compiled. Adding a class to a gem's owners list with no
  other file changed left Rake believing an already-built generated file
  was still up to date, silently serving stale content missing the new
  class while hand-written registration call sites for it had nothing to
  link against. Fixed by adding `compiled_gems.rb` as an explicit
  prerequisite in all three `mrbgem.rake` files.
