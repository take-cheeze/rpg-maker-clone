- **bc2cpp removes left-out native methods from the closed build's method
  tables.** The registration proof now also covers C/C++ methods that
  engine classes register with `mrb_define_method` and the other defining
  calls (RGSS's native classes). The owner's compiled gem removes each one
  the closed list leaves out, as it does a left-out compiled entry. A
  registration call's own name argument no longer counts as a lookup of
  that name. mruby's ROM method tables are not covered.
