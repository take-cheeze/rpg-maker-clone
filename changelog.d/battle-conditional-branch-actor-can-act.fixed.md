- **The battle-page Conditional Branch's "actor can use a battle command"
  sub-test (opcode 13310, `param0 == 2`, `param2 == 3`) is now implemented**,
  instead of always reporting false. Ported from a reference implementation,
  not independently confirmed against genuine RPG_RT under wine: its own
  battle-interpreter actor case and battler "can act" check say the ally can
  use a battle command unless it
  currently carries a "do nothing" restriction (asleep/paralysed-type
  states). Deliberately narrower than `Game::Battle#command_restricted?`
  (`mruby-rpg2k/mrblib/game.rb`), which also flags a Berserk (`attack_enemy`)
  or Confusion (`attack_ally`) restriction — those answer "does this ally get
  a normal command menu," a different question, and a battler under only one
  of them still "can act" by RPG_RT's own `CanAct` definition, just on a
  forced target. `Game::Battle#do_nothing_restricted?`, which already backed
  half of `#command_restricted?`, is now exposed publicly for
  `Game::Interpreter#battle_actor_condition` to call. The sibling "named"
  sub-test (`param2 == 1`) stays unimplemented (false): the reference
  implementation's own actor case never sub-dispatches on a second
  parameter at all (again unconfirmed against genuine RPG_RT under wine), so
  there is no
  known "named" behaviour to match. Covered by new
  `scripts/rpg2k_logic_check.rb` checks, including one that fails against a
  naive `command_restricted?`-based implementation to pin the Berserk/
  Confusion distinction.
