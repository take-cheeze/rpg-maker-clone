- The RPG2000 **field windows show an actor's condition** too, which is where a
  player finds out who needs the antidote: the menu party list, the item and
  skill target lists, and the status screen (a labelled row of its own) each draw
  the significant state in its own palette colour, or the database's
  `normal_status` term when the actor is clear — the three windows RPG_RT shows
  one in (`Window_MenuStatus`, `Window_ActorTarget`, `Window_ActorInfo`). They
  read it through the same `Scene::Base#state_display` the battle status panel
  uses, so the menu and the fight cannot disagree about which state a battler is
  showing. Until now a downed actor read only as `HP 0/120`.
