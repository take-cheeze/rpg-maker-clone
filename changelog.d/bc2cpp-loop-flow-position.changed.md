- **bc2cpp proves sends inside inlined loop bodies from their flow position**: a send in an inlined `each`/`map`/
  `times` body had no flow position, so the closed-world proof could not read its receiver's class set. Now a
  receiver the body defines is judged at the body's own flow, and a method local the body reads (through
  GETUPVAR) at the method's flow at the loop, when the body and the method never write that local. A receiver holding
  the loop element is refused when the body reassigns the element. On the wio closed world's shipped pass, four sends
  in `RPG2k::Scene::Map` (three `wait` sends on a `KeyInputRequest`, one `name` send on a `Game::Shop`) take the proven
  nomethod tail, and their dispatch is a direct call (`bc2cpp_send` 1901 to 1897; `closed_world_kept` 225 to 221).
  `BC2CPP_LOOP_FLOW_POSITION=0` turns the change off (checked by the fixture switch-off case). Covered by
  `scripts/bc2cpp_loop_flow_position_check.rb`. See `docs/adr/0398-bc2cpp-loop-flow-position.md`.
