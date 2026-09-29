- bc2cpp emits the rgss:: native wrappers only when mruby-rgss/src is part of
  NATIVE_SRCS, so a core `Array#clear` no longer links against RGSS symbols.
