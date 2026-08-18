- **Save/load screen:** holding Down/Up now auto-repeats the file cursor
  after the initial delay, matching real RPG_RT — it used to move exactly
  one slot per tap no matter how long the key was held. The repeat timing
  reuses this build's existing, already wine-verified `Input.repeat?`
  signal (first repeat at 24 held frames, then every 4), the same one the
  Enter Number widget already relies on. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
