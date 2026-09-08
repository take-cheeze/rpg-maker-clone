- **WOLF RPG Editor (ウディタ/Woditor)** `SetMoveRoute`(201)/
  `SetVariableEx`(124)'s own `-3..-7` target band (a party member) now
  resolves to a real companion's own position, instead of the "no party
  system exists" no-op it was before the party roster shipped. `Effect`
  (290)'s Character target resolves one too, but still cannot flash/shake
  a party member -- the renderer has no sprite lookup for one yet. See
  `docs/adr/0101-wolf-rpg-editor-move-route-party-target.md`.
