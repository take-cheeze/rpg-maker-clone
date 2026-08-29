- **Upper-layer chipset decorations and obstacles now block movement.**
  `Game::ChipSet` read the upper passage table for the counter flag alone;
  ordinary movement (`char_passable?`, the party's own `passable?`, and the
  jump-landing `char_can_land?`) only ever consulted the lower-layer table, so
  anything drawn on the upper layer — a boulder, a fence post, a shop counter —
  was walked straight through. `ChipSet#passable_tile?` / `#landable_tile?` now
  mirror a reference implementation's approach here — ported, not
  independently confirmed against genuine RPG_RT under wine: an upper tile
  that blocks the direction wins outright; one that permits it but lacks the passage byte's
  `ABOVE_BIT` is solid ground in its own right and the check stops there;
  otherwise (no upper tile, or one flagged `ABOVE_BIT` for a see-through
  decoration like a painted rug) the lower layer's own passability decides, as
  before. A shop/inn counter — impassable on every side with no `ABOVE_BIT` —
  is exactly this case, so the fix also plugs the gap where a counter answered
  the action button but could still be walked onto.
