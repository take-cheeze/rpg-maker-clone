- **bc2cpp class-body self sends and core `Proc#call` splats share one helper each**: the by-name `include` / `attr_*` sends of
  a compiled class body call `bc2cpp_ssend`, and a core `x.call(*args)` calls `bc2cpp_proc_call_argv`, instead of repeating
  an `mrb_funcall_argv` and its argument array at each of ~230 sites.
