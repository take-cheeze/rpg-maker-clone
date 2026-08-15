- **Resuming a save with a shown picture** now restores its zoom, opacity and
  tone from chunk 103, not just the file name and centre position — the save's
  fields use the exact same scale as the live Show Picture command's own
  zoom/transparency/tone parameters, so `Game::State.restore_pictures` converts
  transparency through the same `#trans_to_opacity` the command uses and reads
  zoom/tone straight through, matching `Picture`'s own defaults when a field is
  absent. Covered by a synthetic-chunk round-trip in `rpg2k_logic_check.rb`.
