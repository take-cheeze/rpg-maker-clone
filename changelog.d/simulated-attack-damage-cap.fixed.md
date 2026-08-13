- **Simulated Attack (10500) damage is now hard-capped at 999**, matching
  the same fixed-three-digit-popup cap already applied to a normal attack,
  an attack skill/item, an enemy self-destruct, and per-turn state slip
  damage (`Game::Battle::DAMAGE_CAP`). This raw event command computes its
  own damage independently of `Game::Battle` and had no such ceiling, so a
  high enough Attack Power parameter could deal (and report, via its
  store-in-variable option) far more than RPG_RT's damage display could
  ever show. `Game::Interpreter#do_simulated_attack` now clamps its
  computed damage to `Game::Battle::DAMAGE_CAP` before applying it to HP
  or writing it to a variable.
