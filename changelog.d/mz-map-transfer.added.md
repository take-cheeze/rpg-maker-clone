- **MZ can be shown to leave its start map.** `--mz_transfer_test`
  (`MZ_MODE=transfer`) runs a Transfer Player command through the map
  interpreter to a second map the test bed now carries, and asserts the map id
  changed (`moved=true`), the player landed on the requested tile
  (`landed=true`) and the destination map's *own* parallel event has run
  (`arrived=true`) — the last being the difference between the id moving and the
  map having been fetched, built and set running. Every probe before this ran on
  the one map the bed had, so `Game_Player.reserveTransfer`, `Scene_Map`
  re-creating itself, `DataManager.loadMapData` for a `MapXXX.json` never read at
  boot, and `Game_Map.setupEvents` for an arriving map had no coverage at all.
  The cross-mode frame check gains the matching picture claim.
- **Fixed: the test bed's second map wrote a variable that did not exist.**
  `Game_Variables.setValue` ignores any id at or past the length of
  `$dataSystem.variables` — no error, no warning — and the bed declared one
  variable while the new map's event wrote the second, so the event ran and did
  nothing. The bed now declares both. Same shape as the empty `battlerName` that
  froze MZ's battles and the empty `Items.json` behind its empty menu: a
  hand-authored project can hold values the editor never writes, and the engine
  answers with silence.
