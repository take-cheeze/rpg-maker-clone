- **The action button reaches across a counter, and answers an event underfoot.**
  Pressing it only ever looked at the one tile the party faced. RPG_RT looks in
  three places (EasyRPG's `Game_Player::CheckActionEvent`): the tile the party is
  *standing on* — which is how a trigger-0 event on a doorway answers the button
  — the tile ahead, and then, when that tile is a **counter**, straight through
  it to whoever stands behind, up to three counters deep. A counter is an
  upper-layer tile flagged in the chipset's upper passage table (`Game::ChipSet`
  now reads it, alongside the lower table it already had), and it is how every
  RPG2000 shop and inn is built: an impassable counter with the keeper behind it.
  Two of Nepheshel's 100 chipsets define counter tiles and 25 of its maps place
  203 of them — its shops and inns — so those keepers could not be spoken to at
  all.
