- **MZ's menu is now driven the way a player drives it.** `--mz_menu_play`
  (`MZ_MODE=menu_play`) hands the party a Potion and wounds the actor through
  Change Items / Change HP event commands, then taps confirm through
  `Window_MenuCommand`, the item category, the item list and the actor window,
  and cancel back out — asserting the item healed (`healed=true`), the inventory
  paid for it (`used=true`) and the map came back (`returned=true`). The
  existing check only asserted `Scene_Menu` was *reached*, which is true the
  instant the scene is pushed, before its first update — the same shape of claim
  that had hidden MZ's frozen battles. The menu itself turned out to work first
  time, but the walk found the test bed shipping **no items at all**
  (`Items.json` was `[null]`), so `Scene_Item` had been opening onto an empty
  list with nothing in the project to use; the bed now authors a Potion, and the
  old check still reports `reached_menu=true` on the empty bed the new one fails
  on.
- **A smoke run now ends when its probes have reported, not when its clock runs
  out.** The probes give up after so many *frames* while `--timeout_ms` counts
  *milliseconds*, and a headless software-GL frame costs far more wall clock on
  a loaded host — so a run could be cut off mid-probe, and a cut-off run prints
  no report at all. That is how a battle that was landing damage and cycling
  turns came to be reported as "no attack ever damaged an enemy". Runs now stop
  as soon as every requested probe has had its say (the eight MZ modes take
  11–116s each rather than a flat 60s), the two play-out modes get ceilings
  sized for the slowest host instead of the fastest, and the checks say "the run
  ended before the fight did" when that is what happened.
