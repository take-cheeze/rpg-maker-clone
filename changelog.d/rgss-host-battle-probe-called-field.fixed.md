- The RGSS script host's `--rgss_host_battle_test` probe now reports a
  `called=` field alongside `reached=` in its `[RPGXP-HOST-BATTLE]` log line,
  distinguishing "the game's own `Game_Temp` does not implement the stock
  battle-calling attributes, so the probe never even asked for a battle"
  (`called=false`) from "the battle really was requested but the game's own
  engine never brought `Scene_Battle` up" (`called=true reached=false`) --
  previously both reported identically as `reached=false`, indistinguishable
  without re-deriving which one happened by hand. Found tracing a real,
  large freeware VX Ace release whose own `Game_Temp` is fully replaced by a
  custom one with none of the stock battle-calling attributes at all.
