- **A move-route Face Direction / Turn sub-command now turns a fixed-direction
  event's sprite too**, instead of the drawn facing staying pinned to the
  page's own static direction no matter what a route asked for. Ported from
  a reference implementation, not independently confirmed against genuine
  RPG_RT under wine: its own facing-lock logic
  folds a page's fixed-direction Animation Type (Fixed / Fixed-Continuous /
  Fixed-Graphic) into the same lock an explicit Direction Fix ON sets, but its
  move-route Face-command handling bypasses *any* lock reason unconditionally
  — only ordinary movement's own facing update respects it. This codebase's
  `Game::EventGraphic.frame` instead hardcoded the page's `base_dir` for every
  fixed-direction anim_type outright, discarding the character's live facing
  regardless of source, so an explicit Face Up/Down/Left/Right/Random/Hero/
  Away-from-Hero or Turn sub-command had no visible effect on such an event —
  it kept a Direction-Fix-style lock even after this codebase's earlier "Face
  Direction overrides Direction Fix ON" fix, since that fix never touched the
  render layer's separate, unconditional `base_dir` override. Fixed with a new
  `Character#fixed_facing` flag (set from `Game::EventGraphic.fixed_direction?`
  by `Scene::Map#build_event`, alongside `#facing_locked` as an independent
  source of the same lock) that `#face` (movement-driven turning) now also
  respects, while `#face!` (the Face/Turn sub-commands, already bypassing
  `#facing_locked`) bypasses it too; `EventGraphic.frame` no longer substitutes
  `base_dir` for any anim_type, drawing the character's own live facing
  instead — which stays pinned at the page's own direction through ordinary
  movement and only turns on an explicit facing command. A Fixed Graphic
  event's separate "never animates" behaviour (its walk-frame column staying
  put) is unaffected. Covered by two new `scripts/rpg2k_logic_check.rb` checks
  and a new `scripts/rpg2k_scene_check.rb` check, all three confirmed to fail
  against the pre-fix code before the fix.
