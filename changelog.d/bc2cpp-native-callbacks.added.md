- bc2cpp's native callback scanner (`tools/bc2cpp/native_callbacks.rb`) reports
  which Ruby method names each native registration's C closure can call back
  into, per registered function rather than over every native source. It is
  report-only for now: the Fiber yield analysis still reads the global set.
