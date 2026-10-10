- **bc2cpp proves sends inside inlined loop bodies from their flow position**: a send in an inlined `each`/`map`/
  `times` body had no flow position, so the closed-world proof could not read its receiver's class set. Now a
  receiver the body defines is judged at the body's own flow. A receiver holding the loop
  element is refused when the body reassigns the element. A method local the body reads is not judged this way (it is
  refused), since judging it at the method's flow created new dead fallbacks in mruby-rpg2k. `BC2CPP_LOOP_FLOW_POSITION=0`
  restores the previous output byte for byte. Covered by `scripts/bc2cpp_loop_flow_position_check.rb`. See
  `docs/adr/0398-bc2cpp-loop-flow-position.md`.
