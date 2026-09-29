- **bc2cpp `==` arm on an Integer receiver** no longer reads `mrb_obj_ptr(v)->c` through an
  immediate fixnum (a segfault for a compare such as `5 == nil` that reached the generated
  native-expression arm); Integer is treated like Float and Symbol, by type tag only.
