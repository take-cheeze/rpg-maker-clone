- `Game::State#to_lsd` now writes chunk 108 (SAVE_PARTY_ACTOR) fields 1
  (name) and 2 (title) as the ADR 0014 `"\x01"` placeholder byte unless the
  actor's name/title actually differs from its own database row
  (`Actor#name_changed?`/`#title_changed?`). A genuine kk1.12 save under
  wine carries that placeholder for every roster actor never touched by
  Change Actor Name/Title — this codebase's own writer previously wrote the
  actor's current (here, unchanged-from-default) name/title unconditionally
  instead, which happened to look correct against a save whose party
  actually had been renamed but silently diverged from genuine RPG_RT for
  any untouched actor.
