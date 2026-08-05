- RPG Maker XP map events animate again. `Game::Character#@pattern` was only
  ever assigned when a page set the event's graphic, so every event stood frozen
  on a single frame of its four-frame walk row while it roamed the map -- the
  player animated, nobody else did. Characters now cycle their pattern on each
  step, hold a standing animation for pages with `step_anime`, and fall back to
  the page's own frame once they stop, as RMXP's `Game_Character#update` does.
  Building an event also applies its page's `walk_anime` / `step_anime` flags,
  which were decoded but never reached the character.
