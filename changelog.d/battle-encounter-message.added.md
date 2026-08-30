- The RPG2000 runtime now narrates a battle's opening the way real RPG_RT
  does: one database `encounter` line per visible troop member (name +
  term, matching how `victory`/`level_up`/`item_received` already
  substitute), plus a fixed `special_combat` line appended after them on a
  first-strike ambush — ported from a reference implementation's own
  battle-start scene-action code, not independently confirmed against
  genuine RPG_RT under wine, which has `special_combat` trail
  the per-enemy lines rather than replacing them. A troop member flagged
  invisible is skipped, matching Show Hidden Monster's own `hidden`
  modelling. Shown via the existing action-banner window (the same one a
  landed hit banners) right after the Battle Start SE/BGM and before the
  command phase opens. Covered by three new `scripts/rpg2k_scene_check.rb`
  checks.
