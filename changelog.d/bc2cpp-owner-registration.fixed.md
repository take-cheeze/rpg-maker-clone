- bc2cpp now generates the `mrb_define_method`/`mrb_define_private_method`/
  `mrb_define_class_method` registration for every compiled entry point of a
  `BC2CPP_WIRED_EMBEDDINGS` class itself (`OWNER_METHOD_REGISTRATION`), from
  the same mandatory/optional/rest/keyword/block data its entry wrapper
  already derived its `mrb_get_args` call from, called from each compiled
  gem's `gem_init` next to `bc2cpp_set_instance_tts`. A class whose ivars are
  embedded in an RData struct is only sound when every method that can touch
  them is the compiled one, and that used to depend on a hand-written
  `register.cxx` staying in sync with the generator's own analysis, which had
  drifted (474 of 2141 rpg2k entries were never installed). `Game::Interpreter`
  (25 unregistered entries, `#update` among them), `Game::Transition` (4) and
  `Game::Map` (2) are back in `BC2CPP_WIRED_EMBEDDINGS` now that installation
  no longer depends on that: every Parallel Process on the map, which the
  unregistered `Game::Interpreter#update` had silently killed, runs again.
  `scripts/bc2cpp_wired_embedding_check.rb` now accepts either a generated or
  a hand registration of the same name; a hand one that survives from before
  is a harmless, verified idempotent duplicate. New
  `scripts/bc2cpp_owner_registration_check.rb` covers the generator itself.
