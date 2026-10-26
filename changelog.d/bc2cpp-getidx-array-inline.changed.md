- bc2cpp inlines the exact-Array, Fixnum-index case of `recv[i]` at each call site (`bc2cpp_getidx`), so the common
  read no longer makes a call. Other receivers still take the outlined helper.
