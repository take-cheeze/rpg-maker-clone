- **Save/Load screen:** Holding Down/Up at the last/first save slot no
  longer wraps the cursor around while the key is still held -- matching
  RPG_RT, it now freezes at the boundary slot until the key is released
  and pressed again; a fresh tap still wraps immediately as before.
  Covered by three new `scripts/rpg2k_scene_check.rb` checks.
