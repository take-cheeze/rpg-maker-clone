- **XP / VX / VX Ace** `RGSS::Color.new` and `RGSS::Tone.new` no longer
  require arguments. This was a bug in the engine's own native binding, not
  a script gap: real RGSS3's stock, unmodified `Game_Screen#clear_tone` /
  `#clear_flash` — present in every VX Ace project's default
  `Scripts.rvdata2` — call `Tone.new` and `Color.new` with zero arguments,
  relying on every component defaulting to 0. The native constructors
  wrongly demanded 3 required arguments, so `ArgumentError: wrong number of
  arguments (given 0, expected 3..4)` fired on every VX Ace game that
  constructs a `Game_Screen` — in practice, every VX Ace game the script
  host boots far enough to reach it.
