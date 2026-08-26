- **Save/Continue:** A live Change Sprite Association (10630) graphic
  override now survives Save/Continue the way genuine RPG_RT.exe itself
  persists it -- as fields on the changed actor's own roster entry (chunk
  108, `SAVE_PARTY_ACTOR`), not on the hero's own map-position record (chunk
  104). Previously `Game::State#to_lsd`/`.from_lsd` wrote/read the override
  only on chunk 104, which a genuine RPG_RT.exe save never reads back for
  this at all (confirmed under wine): a save produced by this codebase with
  an active sprite override would show the actor's plain database graphic
  again after a Continue in genuine RPG_RT.exe, and a genuine RPG_RT.exe save
  carrying a live override would silently lose it on Continue here. Also
  fixes the *un*-overridden case: an actor whose database row simply has a
  non-blank default graphic no longer round-trips as though a live override
  had been applied to it.
