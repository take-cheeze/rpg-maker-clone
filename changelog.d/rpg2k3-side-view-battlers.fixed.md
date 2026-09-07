- **RPG2003 side-view battle screen**, measured against a genuine `RPG_RT.EXE`
  under wine (kk1.12) for the first time. The party's own battler sprites were
  never drawn at all: the Battler Animation pose table is **1-based** in real
  data (1 idle, 5 dead, 7 bad-status, 8 defend), so the 0-based pose constants
  selected nothing, and an actor whose database writes no
  `battler_animation` at all (kk1.12's own first hero) was reported as a
  dangling id instead of falling back to table entry 1. Automatic placement
  also landed every battler 24px right and 24px low — the grid slot is the
  sprite's centre-x / bottom-y anchor, not its top-left — and its y term is
  linear in the terrain's `grid_elongation`, not sinusoidal. The RPG2003 gauge
  card panel is borderless, so its faces and bars now start at the panel rect
  itself rather than 8px inside it; it draws the third, ATB ("T") bar the real
  runtime shows; and the gauge layout floats the actor command window at
  (0, 80), above the cards, instead of beside the status panel.
