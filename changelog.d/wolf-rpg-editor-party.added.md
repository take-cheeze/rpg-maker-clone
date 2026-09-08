- **WOLF RPG Editor (ウディタ/Woditor)** `Party`(270) now has a real party
  roster: `Remove`/`Insert`/`Replace`/`RemoveGraphic` edit up to 5
  companions trailing the hero, `EraseAllCharacters`/`WarpPartyToHero`
  act on that real roster instead of a trivially-empty one, and companions
  actually walk in formation one tile behind the hero (or the previous
  companion), toggled by `TurnOnPartyFollowing`/`TurnOffPartyFollowing`,
  matching the manual's own default. Drawn as small colour blocks, the
  same fidelity the hero itself is still at. Formation-synchro,
  transparency, and memorize/recall stay unimplemented (0 real calls,
  each needing a new rendering/snapshot concept with no real shape to
  confirm a design against). See `docs/adr/0099-wolf-rpg-editor-party-system.md`.
