- **bc2cpp:** compiled code no longer runs a private or protected method
  called with an explicit receiver. The single-owner direct call and the
  class-checked chain arms skipped the visibility check OP_SEND makes, so
  `obj.hidden` returned a value where the interpreter raises NoMethodError.
  Only a public def whose visibility nothing in the program changes is
  called directly; the rest keeps the checked dispatch.
