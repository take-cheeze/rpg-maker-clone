- **Debugging tooling:** The F9 debug menu's Switch/Variable pages now match
  real RPG_RT.exe's own two-level, two-window navigation, verified directly
  against the genuine runtime under wine rather than guessed. RPG_RT draws
  these two pages as a left window listing ten coarse "blocks" of ten ids
  each and a right window previewing the highlighted block's own ten
  individual ids, with independent block-focus (Up/Down +-1 block,
  wrapping within the current 100-id screen; Left/Right pages a whole
  screen, preserving the highlighted block's index; C drills into the
  block) and row-focus (Up/Down +-1 id, wrapping within the block; C
  toggles a switch or opens the variable editor; B returns to block focus)
  cursors, both auto-repeating on a held key. This codebase previously drew
  a single flat, ten-row list per screen with Up/Down moving by one id,
  L/R jumping by ten, and Left/Right always cycling to the next of this
  codebase's five debug pages -- none of which matches the genuine
  runtime. Left/Right no longer cycles pages on Switch/Variable (that
  input pages the screen there now); cycling those two pages moved to the
  L/R shoulder buttons instead, freed up by that change. Map, Chipset and
  Animation (this codebase's own additions, not part of genuine RPG_RT's
  F9 menu) are unchanged, including still cycling on Left/Right.
