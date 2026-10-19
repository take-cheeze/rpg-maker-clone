- **bc2cpp** no longer decides a literal name, block or splat from one arm of a
  join. Its guards for `instance_variable_set` names, instance-eval blocks,
  `alias_method` names and computed send names now read every reaching
  definition, so a parameter or non-literal block on one arm of `c ? x : :name`
  disables the proof it used to pass. A fixnum-or-nil ivar declaration no longer
  tolerates a site with an other-typed arm (`c ? "s" : nil`), and a splat
  literal is taken only when it is the one write that reaches the call.
