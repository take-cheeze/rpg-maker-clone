- **A battle turn-order tie between two allies now breaks by the lower
  actor id, not party seat order.** `Game::Battle#turn_order` tie-broke an
  agility tie by each battler's position in the `@allies + @enemies` array
  (party seat/join order, which `Game::Party#add_actor` builds by append —
  it can diverge from actor id once a member has left and rejoined behind a
  different one). Real RPG_RT ties by actor id instead. Also hardened the
  existing "an ally always acts before an equally-fast enemy" rule to key
  off whether a `Combatant` carries a source actor at all, rather than
  relying on every ally happening to sit at a lower array index than every
  enemy. Regression coverage added to `scripts/rpg2k_logic_check.rb`,
  confirmed to fail against the pre-fix code.
