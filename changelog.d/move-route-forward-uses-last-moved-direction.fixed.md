- **A move-route "One Step Forward" now continues in the direction actually
  last walked/jumped, not the sprite's displayed facing.** The two can
  diverge under a Direction Fix lock (a locked `Move Right` steps east
  without turning the sprite) or an explicit Face command (`Face Up` turns
  the sprite north without moving), and `Game::MoveRoute`'s `MOVE_FORWARD`
  handler read `Character#direction` — the sprite facing — so a route that
  mixed the two stepped the wrong way. `Character` gained a new
  `#last_move_direction` reader, updated by `#move`/`#jump`/`#move_diagonal`
  alongside (but independently of) `#direction`, and `MOVE_FORWARD` now reads
  that instead. Covered by a new `scripts/rpg2k_logic_check.rb` check
  (Direction Fix ON, a locked Move Right, an explicit Face Up, then One Step
  Forward continues east, not north), confirmed to fail against the pre-fix
  code before the fix.
