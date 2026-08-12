- **The menu's Save command now records the real save count in exported
  `Save<N>.lsd` files.** `Game::State#save_game` (invoked by `Scene::Menu`'s
  Save command) incremented `state.save_count` but never passed it to
  `#to_lsd`, so every exported `.lsd` reported save #1 forever regardless of
  how many times the player had actually saved. `Game::State.from_lsd` also
  never read the field back, dropping it silently on Continue. Both directions
  are now wired through the system chunk's `save_count` field (131), the same
  way the access flags already round-trip, and pinned by
  `scripts/rpg2k_save_load_check.rb`.
