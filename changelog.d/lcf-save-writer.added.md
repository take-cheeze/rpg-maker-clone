- The LCF layer can now **write** `LcfSaveData`, not just read it. New inverse
  primitives in `mruby-lcf` -- `LCF.write_ber` (the exact inverse of `read_ber`),
  `LCF.encode` for scalar/simple-array field types, `Array1D#to_lcf` /
  `Array2D#to_lcf` / `File#to_lcf` / `File#save_to`, and `Array1D#[]=` to edit a
  parsed save through its schema -- serialize a save back to bytes. Because the
  reader keeps every chunk's raw payload (including the undocumented chunks 102,
  112, 200), a save read and re-serialized reproduces the original **byte for
  byte**: `scripts/lcf_save_roundtrip.rb` proves this against the real RPG2000
  (Nepheshel, 17797 B) and RPG2003 (mtf-meido-action, 11132 B) fixtures, and also
  edits the hero position / save counter through the schema and confirms the
  change survives a write/reload. `scripts/gen-lcf-save-wine.bash` runs the
  round-trip harness after generating a save. This is the serializer a future
  real-format in-game Save (`Game::State#to_lsd`) will build on. See ADR 0018.
