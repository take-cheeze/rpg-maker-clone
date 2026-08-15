- **Battle**: a party member added or removed mid-fight by a `Change Party
  Member` battle event now actually appears or disappears on the battle
  screen the instant it happens, instead of the status window and RPG2003's
  actor battle sprites staying pinned to whoever was in the party when the
  fight opened. `Interpreter#do_change_party` notifies the open battle
  screen the moment a real membership change happens (mirroring EasyRPG's
  `Game_Party::AddActor`/`RemoveActor` calling `Scene_Battle_Rpg2k::
  OnPartyChanged` synchronously); the screen builds or disposes that one
  actor's sprite, updates `@battle_ui[:allies]`, and redraws the status
  window immediately -- covering the RPG2003 gauge-card layout
  (`battle_type` 2) the same way as the plain text rows, since both already
  read from the same roster. A member who leaves and rejoins the same fight
  is drawn with a freshly built sprite (never a disposed-and-reused one)
  while reusing the same `Combatant` the mechanics keep for them (ADR 0050),
  so their accumulated battle-only state still survives the round trip.
  This is the rendering follow-up ADR 0050 (mid-battle party roster sync)
  deliberately deferred; see ADR 0051.
