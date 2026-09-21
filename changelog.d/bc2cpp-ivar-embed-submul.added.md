- **bc2cpp** now proves an ivar embeddable when a `SUB`/`SUBI`/`MUL`
  bytecode opcode's operands are themselves recursively proven Fixnum --
  the common `@counter -= 1`/`@frames -= 1` countdown idiom. Unlike the
  existing `ADD`/`ADDI` case (trusted unconditionally), this requires a
  full recursive operand proof, since real mruby's `OP_SUB`/`OP_MUL` can
  produce a Float from mixed operand types. Verified against the real
  project's own 3 compiled gems: 7 new embedded ivars (all frame/counter
  fixnum fields, e.g. `Game::Screen#@frames`, `RPG2k::Scene::Order#@counter`),
  15 fewer dynamic dispatch sites, `#error` count unchanged at 0. The
  standalone Optcarrot bc2cpp probe gains 6 more embedded ivars.
