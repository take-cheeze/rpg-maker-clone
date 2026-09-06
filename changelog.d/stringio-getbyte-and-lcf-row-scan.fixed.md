- **Cut the New Game/Continue transition stall by ~64%** by fixing two
  interpreter-level inefficiencies on the LCF row-scanning hot path: `StringIO`
  had no native `getbyte`, so `mruby-lcf` emulated one via `getc.getbyte(0)`,
  allocating a throwaway one-character `String` on every single byte scanned
  while walking a table's chunk boundaries; and `LCF::Array2D#read_row_bytes`
  rebuilt its captured row bytes with `out = out + ...`, reallocating and
  copying the whole accumulated buffer on every chunk instead of appending in
  place. Added a real `StringIO#getbyte` (`3rd/mruby-stringio/src/stringio.c`,
  mirroring `IO#getbyte`'s no-allocation Integer return) and switched
  `read_row_bytes` to `<<` (`mruby-lcf/mrblib/lcf.rb`); declared the
  `mruby-string-ext` dependency `<<` needs directly on `mruby-lcf` rather than
  relying on it arriving transitively. Neither change is RPG2000-specific —
  every lazily-decoded LCF table (items, actors, common events, maps, ...)
  goes through this same path. Measured on Nepheshel's `--rpg2k_new_game`
  repro: `map.transition.party` 232ms → ~83ms, `map.transition.common_events`
  138ms → ~50ms, worst frame ~410ms → ~145-150ms. See docs/profiling.md's
  "The New Game/Continue transition" section for the full investigation and
  why the remaining ~145ms is real, proportional work left for a separate,
  larger frame-spreading follow-up rather than fixed here.
