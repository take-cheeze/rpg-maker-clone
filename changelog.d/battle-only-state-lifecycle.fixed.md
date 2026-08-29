- **Battle-only states (situation table `type` 0, the default) now clear at
  battle end instead of surviving onto the field party.** `Game::Battle
  #apply_to_party` (`mruby-rpg2k/mrblib/game.rb`) copied every combatant's
  `states` back onto its persistent `Game::Actor` unconditionally, so a state
  the database flagged "battle only" survived past battle end exactly as
  much as one flagged "also on map" (`type` 1) — a status the player could
  never have cured outside battle then sat on the field roster indefinitely.
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: its own battle-end state cleanup,
  called when the battle scene quits, removes exactly the states whose own
  persistence flag says "ends" and leaves
  the "persists" ones alone — this codebase's own `schema.rb` decodes
  the same field, under the name `type`, with the matching comment ("0:
  battle only, 1: also on map"), but nothing in the runtime ever consulted
  it. Fixed with a new `Game::Battle::STATE_PERSISTS_ON_MAP` constant and a
  `#surviving_states` filter applied inside `#apply_to_party`, reusing the
  existing `#state_def`/`#state_field` lookup pattern (a state whose row
  can't be found is dropped rather than guessed at, matching this file's
  usual dangling-reference handling). Covered by new
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
