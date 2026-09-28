- Lower proven `.new` calls to direct object construction. Use compiled
  `#initialize` bodies when their class and calling convention are proven;
  otherwise use mruby's `mrb_obj_new` to preserve ordinary initializer dispatch.
