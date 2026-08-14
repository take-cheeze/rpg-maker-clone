- **Pan Screen's offset and Lock now survive a save/load** through this
  codebase's own authoritative Marshal save (`Game::State#to_h`/`.load`),
  instead of silently snapping the camera back to hero-centred and unlocked
  on every Continue. `@screen` was the one nested `Game::State` object with
  no serialisation at all — `@weather`, every vehicle, the message config
  and everything else already round-trip through a `to_h`/`load_h` pair. A
  cutscene that pans the camera and locks it (so the hero stops re-centring
  the view) can leave that mode active indefinitely, and a Save event or the
  menu's own Save command taken while it holds used to lose the state
  entirely, with no way for a script to detect it. Fixed with a new
  `Game::Screen#to_h`/`#load_h` pair scoped to `pan_x`/`pan_y`/`pan_tx`/
  `pan_ty`/`pan_step`/`pan_locked` — a pan mid-scroll when the game is saved
  now resumes the rest of that scroll on load rather than jumping straight to
  (or stopping short of) its destination. Every other screen effect (tint
  transition, shake, flash, fade) stays deliberately transient, reset on
  every load exactly as before. The `.lsd` export (`State#to_lsd`/
  `.from_lsd`) is untouched — real RPG_RT's own save chunk stores an
  absolute camera pixel position rather than a hero-relative pan offset,
  which needs a live camera reading from the open `Scene::Map` at save time,
  a separate, bigger question left open. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
