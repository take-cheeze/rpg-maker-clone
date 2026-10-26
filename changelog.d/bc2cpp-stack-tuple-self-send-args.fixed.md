- **bc2cpp**: a self call (`bounce(character, world, [2, 8])`) no longer receives `nil` in place of an Array literal
  argument. The stack tuple analysis did not see a self send read its arguments, so it kept the literal in a C buffer
  and cleared the register that should have held it. Random and bouncing event movement on maps 7, 346 and 412 of the
  trace game raised NoMethodError from this. The event movement and draw error messages now name the event id
  correctly (`e.id`, not `e[:id]`), so a failed step logs a message and no longer raises a second error.
