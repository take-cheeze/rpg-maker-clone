- A runtime-checked return declaration (`%a{bc2cpp:hint}`) whose name another
  definition outside the program also defines (native `inspect`, for example)
  admits no return fact, so nothing relies on it. Its body no longer needs a
  compiled check, which lets a program with such a method compile instead of
  stopping at DECLARED_RETURN_GUARD.
