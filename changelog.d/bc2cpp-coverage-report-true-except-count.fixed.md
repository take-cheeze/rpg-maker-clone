- `docs/bc2cpp_coverage.txt` was stale relative to a real, fully-patched
  build -- the freshness check this round just added (`scripts/
  bc2cpp_coverage_check.bash`) caught it immediately on its first real CI
  run. Root-caused rather than assumed: a standalone `rake` build of the
  host `mrbc` this project's own build normally bootstraps needs every
  patch `cmake/build-mruby.cmake` applies to the vendored `3rd/mruby`
  submodule (`patches/mruby-*.patch`, nine of them) -- without them
  (confirmed by applying each individually and re-diffing) the committed
  file's own `unhandled opcode EXCEPT` count reads 7 where a correctly
  patched build reports 8, shifting the whole-program `compiled entry
  points`/`methods attempted` totals along with it. Verified this drift is
  NOT caused by this round's own optional-arg call-site devirtualization
  work: regenerating against both the pre- and post-devirtualization
  `bc2cpp.rb` with the same properly patched `mrbc` produces the identical
  6-method `EXCEPT` set either way (`RPG2k#start`, `RPG2k::Scene::
  Map#build_resolver`/`#try_open_debug_menu`/`#perform_teleport`,
  `RGSS.singleton#audio_probe`, `RGSS::Graphics.singleton#_transition_map`)
  -- the file was already wrong the moment it was first committed, this
  round's own new CI check is just the first thing to ever verify it
  against a real, fully-patched build.
