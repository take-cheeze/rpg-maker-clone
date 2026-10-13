- The nightly `bc2cpp-checks (rpg2k-singleton-owners)` shard no longer fails. Its fixture slicer used Prism byte
  offsets as character indices, so the multibyte comments in `game.rb` cut the generated fixture mid-method under a
  UTF-8 locale. The check now also accepts the `CLOSED_WORLD_CONSTANT_OBJECT` label for `Game::CommonEvent.load`,
  matches the hot-only guard `register.cxx` has used since ADR 0428, and no longer crashes when `RSO_WORLDS` leaves
  out a world its wiring section reads.
