- RPG Maker 2000: `scripts/analyze_game.rb` gained a **`--troops`** mode that
  reports a game's troop battle-event pages — how many carry a condition, which
  condition-flag bits they use, the turn base/multiple pairs and enemy-HP windows
  those bits imply, which battle-only commands the pages run, and whether any
  command lacks a handler. This is what validates `Game::BattlePage`'s flag bit
  assignments against **real bytes** rather than against liblcf's declaration
  order alone, per ADR 0002.
  Run against Nepheshel (3265 troop pages, 2819 conditional) it confirms four
  bits: `switch_a` (0) and `switch_b` (1) — bit 1 only ever appears alongside
  bit 0 and those pages carry a *pair* of plausible switch ids; `turn` (3) — 156
  pages fire on turn 0 and 9 fire every turn, exactly the two shapes
  `check_turns` produces; and `enemy_hp` (5) — every page carries a deliberate
  `0..30%` window rather than the `0..100` default, which a wrong bit could not
  survive. The remaining bits are unused by that game and still rest on the
  declaration order, but the data shows the order is not shifted. It also
  confirms **every battle-only command Nepheshel's pages use has a handler**
  (Change Monster MP / Condition, Show Hidden Monster, Change Battle Background,
  the battle Show Battle Animation, and 6577 battle Conditional Branches with
  their matching `_B` end markers). The battle opcodes are named in the report's
  label table too.
