- **Entering a battle with no living party member (an emptied party, or one
  left fully KO'd) now settles as an instant defeat**, instead of freezing
  the fight open on a blank command menu forever. `Scene::Map
  #draw_battle_command`'s `current_actor` already resolved to `nil` for
  either case and quietly declined to draw a command window (`return unless
  actor`), but nothing then advanced the fight — a round only ever starts
  once the player picks a command via that window — so `#open_battle` left
  the encounter stuck in its `:command` phase indefinitely rather than
  reaching the `Game::Battle#finished?` check every other round already
  settles through. Fixed with a new `#settle_already_finished_battle`,
  called from `#open_battle` right after Turn-0 battle-event pages get their
  chance to run: when `Game::Battle#finished?` already reads true (no living
  ally), it calls `Game::Battle#end_round` to compute the result and drives
  the scene straight to the defeat result screen the same way an ordinary
  round's own wipeout would. `#finish_battle`'s existing `all_dead?` check
  (which already reads an empty actor list as "all dead") then turns that
  into a genuine Game Over once the result screen is dismissed, unaffected
  by this fix — it only needed to be reachable in the first place.
