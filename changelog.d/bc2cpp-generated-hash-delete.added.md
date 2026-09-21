- bc2cpp now generates an exact-Hash path for mruby core's internal
  `Hash#__delete` wrapper from its C registration and body, preserving the
  wrapper's call-info write and public deletion helper call.
