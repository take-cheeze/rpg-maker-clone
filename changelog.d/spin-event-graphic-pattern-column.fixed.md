- **A spinning event now keeps its own pattern column instead of freezing on
  column 1.** `Game::EventGraphic.frame`'s `SPIN` case (animation type 5,
  "show in all directions") hardcoded the CharSet column to `1` while cycling
  the row through the spin sequence, on the assumption that a spinning
  character just turns in place on its standing pose. That silently
  discarded the page's own `pattern` field, which matters whenever a CharSet
  slot is repurposed to store unrelated single-frame pictures across its 3
  columns rather than a walk cycle -- Nepheshel's Crystal Gate save point
  (map 12, event 5, `object1r` index 4) is exactly that: column 0 is the lit
  flame, column 2 the unlit device, and its active page sets `pattern: 0`.
  With the column forced to 1 the event spun through column 1's *own*
  unrelated picture (a blue crystal pillar) instead of flickering through
  its four lit/unlit flame frames. `frame` now returns `[spin_direction(phase),
  base_pattern]`, matching the doc comment above it (`animate_event` already
  cycles a spin event's phase "to pick the drawn column"). Pinned by
  `scripts/rpg2k_render_check.rb`.
