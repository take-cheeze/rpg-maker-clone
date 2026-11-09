- **bc2cpp:** a compiled explicit-receiver call of a protected method runs it
  when the caller's `self` is a kind of the method's class or module, as the
  bumped mruby's interpreter now does, instead of always raising NoMethodError.
