- **LCF schema completeness.** The parser now names every chunk the real
  test beds actually write, so no game data is left as an unnamed raw blob.
  The four RPG2003-only top-level database sections between the 2000
  common-events table and the 2003 battle-commands list and between Classes
  and Battler-Animation (chunks 26/27/28 and 31) are declared as bare
  `Array2D` tables (present-but-empty in the mtf-meido-action test bed, so
  their record layout is not yet transcribed — they preserve any real bytes a
  non-empty project writes and stay nameable instead of raising on access),
  and the two top-level `battlecommands` (chunk 29) fields 9 and 24 —
  single-byte ints in the test bed — are declared as plain `:int` so they
  round-trip and are nameable rather than guessed at their RPG_RT meaning. A
  new `scripts/lcf_schema_coverage.rb` walks every test-bed `.ldb`/`.lmt`/
  `Map*.lmu` and fails if any chunk the parser stores is left unnamed, making
  schema completeness a checked invariant instead of an eyeball audit.
