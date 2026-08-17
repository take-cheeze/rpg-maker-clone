- **RPG2003's in-battle Row command** is implemented: an actor's front/back
  row (`Game::Actor#battle_row`, persisted across Save/Continue via LSD
  SaveActor field `0x5B`/91) can now be flipped mid-fight through the Row
  battle-menu entry, feeding the existing hit/damage row adjustments (ADR
  0053). RPG_RT's own "can't empty the front row" guard is ported too — a
  blocked toggle plays the Buzzer SE and stays on the command menu instead of
  spending the actor's turn.
