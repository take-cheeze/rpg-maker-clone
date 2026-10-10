- **bc2cpp proves sends inside inlined loop bodies from their flow position**: a send in an inlined `each`/`map`/
  `times` body had no flow position, so the closed-world proof could not read its receiver's class set. Now a
  receiver the body defines is judged at the body's own flow, and a method local the body reads (through
  GETUPVAR) at the method's flow at the loop, when the body never writes that local. A receiver holding the loop
  element is refused when the body reassigns the element. On the wio closed world's shipped pass, the `wait` sends
  on a proven `KeyInputRequest` in `RPG2k::Scene::Map#resolve_key_input` take the proven nomethod tail (singleton
  definer kept sites 9 to 6, `closed_world_kept` 226 to 220). `BC2CPP_LOOP_FLOW_POSITION=0` restores the previous
  output byte for byte. Covered by `scripts/bc2cpp_loop_flow_position_check.rb`. See
  `docs/adr/0398-bc2cpp-loop-flow-position.md`.
