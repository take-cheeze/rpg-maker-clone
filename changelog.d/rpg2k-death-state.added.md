- RPG Maker 2000: the **death state (戦闘不能, state id 1)** is now coupled to HP,
  and events can change conditions. `Game::Actor` gains `dead?` / `alive?`, and
  the coupling mirrors a reference implementation's own death-state id (not
  independently confirmed against genuine RPG_RT under wine): lethal `change_hp`
  (death allowed) knocks the actor out — HP hits 0 and state 1 is inflicted —
  while inflicting state 1 directly zeroes HP. A downed actor is unaffected by HP
  changes (healing can't revive it); curing the death state, or **Full Recovery**,
  revives at 1 HP. Because a downed actor is HP 0 **and** state 1, and both fields
  already round-trip (chunk 108's HP field 71 and the state fields 81/82), a
  knocked-out party member stays down across **Continue** — the `.lsd` round-trip
  test now KOs the leader and asserts it. The **Change Condition** event command
  (10480) is wired: it inflicts (op 0) or cures (op 1) a state on the targeted
  actors (same scope layout as Change HP), so an event can poison, cure, KO, or
  revive — reviving via removing state 1 stands the actor back up. Grounded
  against a reference implementation's own HP/state-change and
  change-condition handling (not independently confirmed against genuine
  RPG_RT under wine), and covered by new
  `scripts/rpg2k_logic_check.rb` checks (the HP↔death coupling, the command) and
  the downed-leader `.lsd` round-trip in `scripts/rpg2k_save_load_check.rb`.
  Inflicting states from battle / skills (rolling `state_chance`) and party-wipe
  game over remain follow-ups.
