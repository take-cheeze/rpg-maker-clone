- An empty enemy troop (every member removed via a Change Monster HP-style
  data edit, or a database misconfiguration) no longer runs its own turn-0
  battle event page before the fight settles as an instant victory --
  community デフォ戦bot/@2000_battle_bot trivia. `Scene::Battle#start` and
  `#drive_battle_encounter_message` used to call `#run_battle_events` before
  `#settle_already_finished_battle`, so a page conditioned on turn 0 alone
  still got a chance to fire even though the fight was already
  `battle.finished?` from frame one; reordered to settle first.
