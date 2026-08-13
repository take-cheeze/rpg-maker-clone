- **A Change Parameters event command's stat adjustment now survives Save /
  Continue**, instead of silently reverting to the level-derived default the
  moment the game reloads. Continue always rebuilds the actor roster as
  fresh `Game::Actor` objects seeded from the database's `initial_level`
  (`Game::State.load` → a new `Game::Party`), and `Party#to_h` never wrote
  `@base`/`@base_raw` (the stat total `Actor#change_param` maintains, clamped
  and unclamped) into the save at all — so a live adjustment had nowhere to
  land on the reloaded actor even before `#load_state` touched it, and was
  actively overwritten on top of that in the common case: restoring the
  saved EXP through `#set_exp` calls `#set_level` whenever the computed
  level differs from the fresh object's own (true of almost any real save,
  since gameplay has usually raised the level past its starting point), and
  `#set_level` deliberately re-seeds `@base`/`@base_raw` from the
  level-derived growth-curve baseline. `Party#to_h` now writes each roster
  actor's `base_raw` into `actor_meta` alongside the existing name/title/
  sprite overrides, and `#load_state` calls a new `Actor#restore_base` right
  after `#set_exp` — deliberately after, since `#set_exp` is what does the
  re-seeding that needs undoing — which re-applies the saved unclamped total
  and re-derives the clamped `@base` from it with the identical clamp
  `#change_param` itself uses (now shared as `#base_param_limit`). A save
  written before `base_raw` existed simply keeps the level-derived baseline,
  unchanged from before this fix. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks (a Change Parameters adjustment —
  including one still resting on the unclamped floor from a bigger drop —
  round-trips through `Party#to_h` / `#load_state` into a fresh `Party`
  unchanged; a save with no `base_raw` field falls back to the level-derived
  default), the first confirmed to fail against the pre-fix code before the
  fix.
