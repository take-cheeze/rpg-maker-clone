- **Enter Hero Name (10740).** The event command that lets the player rename a
  party actor is now playable. The interpreter suspends on a `:name_input` wait
  carrying the target actor and (when the command asks for it) the actor's
  current name as a seed, and `Scene::Map` drives a character-entry widget: a grid
  of the Latin letters, digits and a few punctuation marks plus BS (backspace) and
  OK cells, with arrow-key cursor movement, C to type / act on a cell and B to
  backspace. Confirming on OK commits the entered name to the actor (a blank entry
  keeps the previous name, as RPG_RT does) and resumes the event; a command
  targeting an actor this build never instantiated is a no-op. The hiragana /
  katakana / symbol pages RPG2000's own screen offers are a later refinement.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` (the command suspends
  and seeds correctly, resume renames the actor, a blank entry and a non-party
  actor are no-ops) and `scripts/rpg2k_scene_check.rb` (typing a character on the
  grid and confirming on OK renames the actor and resumes the event).
