- **Enter Hero Name (10740)** now draws RPG_RT's own screen for its hiragana
  and katakana character sets (param1 0/1): a face box showing the target
  actor's default FaceSet portrait, a name-so-far field with a blinking cursor
  box on the next empty slot, and a gojuuon grid below them — eight rows of
  the plain kana beside their voiced/semi-voiced column, small kana, the
  long-vowel mark and a symbol row, then a final row of six kana plus
  double-width toggle (`かな`/`カナ`) and confirm (`決定`) cells. Arrow keys
  move the cursor with the grid's own row/column wrap, C types the
  highlighted kana or acts on toggle/confirm, B backspaces, and confirming
  commits the entered name (up to 6 kana) to the actor and resumes the event.
  The Latin/digit grid (param1 2, for English-patched games) is unchanged.
  `Game::Actor` now carries the actor's `face_name`/`face_index` (from the
  database's faceset chunk) for the portrait box to read. Covered by new
  checks in `scripts/rpg2k_scene_check.rb` (the widget opens on the requested
  page and seed, typing and confirming a kana renames the actor, the toggle
  cell swaps pages, the field stops at 6 characters, and the grid cursor
  wraps around its ragged last row).
