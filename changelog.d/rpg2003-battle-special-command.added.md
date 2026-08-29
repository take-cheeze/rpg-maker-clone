- The RPG2003 **Special** battle command (type 6 in the Battle Commands table)
  is now driven: a customized menu that names a Special entry offers it as a
  row, and choosing it forfeits the actor's turn — a reference implementation
  queues a no-op action for it, not independently confirmed against genuine
  RPG_RT under wine, so the actor spends its turn (and, in a gauge battle, its held
  charge) with no action, message or animation (`Game::Battle#command_skip`,
  the same no-op a failed escape produces). The chosen command is still
  recorded for the battle-page `command_actor` condition and the Enable Combo
  matching (which never multiplies a Special). Previously the handler was
  skipped along with Escape. Covered by new `rpg2k_scene_check.rb` checks (a
  Special-only customized list drawing and committing at once in a round
  battle, and the gauge-battle counterpart spending the ready actor's gauge
  and returning to the ATB loop).
