- RPG Maker 2003: the troop battle-event page conditions that used to fail
  unchecked now resolve. **Per-battler turn counters** — RPG2003 counts turns per
  battler as well as per battle, so `Game::Battle::Combatant` carries its own
  `battle_turn`, bumped as that battler's turn begins (ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine), and the `turn_enemy` / `turn_actor` conditions read
  it through the same base/multiple turn arithmetic the battle-wide turn test
  uses. **Party fatigue** is computed the way a reference implementation's
  equivalent does — ported, not independently confirmed against genuine
  RPG_RT under wine — HP two thirds of the weight, SP the other third, so a
  party at full HP with no
  SP left still reads 33 and an SP-less party divides by 1 rather than 0 — and
  the `fatigue` condition tests it against the page's window. Both were
  previously listed as conditions the runtime could not answer, which meant a
  page gated on either never fired.

  The `command_actor` (chosen battle command) condition still fails its page
  deliberately: RPG_RT only answers it for the battler whose action triggered
  the check, and this runtime evaluates pages once per turn with no acting
  battler — the same null-`source` case a reference implementation bails on,
  a detail ported from it and not independently confirmed against genuine
  RPG_RT under wine. The reason is now
  written down where the condition is evaluated.
