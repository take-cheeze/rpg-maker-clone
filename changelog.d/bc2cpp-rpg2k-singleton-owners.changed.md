- **bc2cpp** compiles `Game::CommonEvent.load`/`.eligible` and
  `Game::MoveRoute.from_page`/`.same_route?` (their `.singleton` owners join
  `mruby-rpg2k-compiled`, registered in full builds only, so the flash-limited
  hot-only builds are byte-for-byte unchanged apart from four empty constants),
  and accepts a bare `new(a, k: v)` in a class method of a class with no
  descendants as a keyword-aware direct construct (so `from_page` compiles only
  in a closed world; the desktop build keeps it bytecode and its registration
  follows the new `BC2CPP_SKIPPED_<entry>` macros the generator defines for
  refused entries). Their call sites in `Scene::Map` become direct C++ calls. `BC2CPP_NSC_DEBUG=1` now names why a
  candidate was not compiled clean. Covered by
  `scripts/bc2cpp/rpg2k_singleton_owners_check.rb` and its mutation check; see
  `docs/adr/0426-bc2cpp-rpg2k-singleton-owners.md`.
