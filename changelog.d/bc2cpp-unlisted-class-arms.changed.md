- **bc2cpp resolves the exact-class arms of definer classes a guard chain cannot
  list**: an `attr_reader`/`attr_writer` becomes a direct ivar access, a private
  def a direct call (implicit receiver) or the VM's `NoMethodError` (explicit
  receiver), a class whose chain defines nothing the final `else`'s
  `NoMethodError`, and a name the RGSS natives also register is proven on the
  class's own chain. By-name `bc2cpp_send` sites on the wio closed world drop
  from 5,081 to 3,918. The synthesized embedded `attr_writer` now raises
  `FrozenError` on a frozen receiver. Covered by
  `scripts/bc2cpp_unlisted_class_call_check.rb`. See
  `docs/adr/0297-bc2cpp-unlisted-class-arms.md`.
