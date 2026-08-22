- **The `--iterm`/`--sixel` terminal backends can now trigger L/R** (the
  shoulder-button pair RPG2000/2003 uses throughout — DebugMenu's page/block
  jumps, the debug editors' layer/mode switches, shop and formation-change
  scrolling, and more) via the **L**/**R** keys. Unlike Ctrl/Shift (bound to
  **T**/**F** since a raw terminal can't tell those modifiers apart from an
  ordinary keypress), L/R had no terminal binding at all — not a deliberate
  gap, just never wired up — so anything gated on them was unreachable from
  either terminal backend. The on-screen control legend and README now
  mention them too.
