- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 4 of
  `RPG2k::Scene::GameOver`'s own 7 real bytecode methods (the RPG2000 Game
  Over screen) and 3 of `Game::Actors`'s own 6 (the actor-cache/lookup
  container, distinct from `Game::Actor` itself). Both added to
  `mruby-rpg2k-compiled`, neither needing any new opcode work.

  This round's own dedicated bug-hunt pass (run in parallel with the
  coverage work, the second such pass in a row to find a live bug) found
  and fixed a fourth severe, live, already-shipped bug in the MONO/POLY
  devirtualization registry: `Struct.new(:a, :b, ...) do ... end` blocks
  were completely invisible to it, in two distinct ways at once -- a real
  `def` written inside the block was never registered at all (no
  `CLASS`/`MODULE` opcode ever fires for `Struct.new`, so nothing recursed
  into the block's own body), and the plain member names `Struct.new`
  installs natively as readers/writers were invisible the same way
  `attr_reader`/`writer`/`accessor` already were before the previous
  round's fix. Confirmed live in two already-shipped compiled methods:
  `Game::Battle#cure_state`'s own `target.state?(sid)` (`target` a real
  `Game::Battle::Combatant`, a `Struct.new(...) do ... end`) devirtualized
  straight into `Game::Actor`'s own bytecode-defined `#state?`, whose body
  reads an `@states` ivar that doesn't exist on a `Struct` instance --
  `nil.include?(state_id)`, a guaranteed `NoMethodError` on every state
  cure in battle. `Game::Battle#combatant_permanent_states`'s own
  `target.actor` had the identical shape against `RPG2k::Scene::EquipMenu
  #actor`, across 19 real call sites. Both in a build that compiled and
  linked clean with zero warnings. Fixed by recognizing a bare
  `Struct.new` call site, registering each member as a synthetic registry
  entry, and recursing the registry walk into the block's own body so a
  real `def` inside it is registered like any other class member. Verified
  against the real generated code before and after for both instances. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
