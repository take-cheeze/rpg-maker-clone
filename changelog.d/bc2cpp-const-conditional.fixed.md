- bc2cpp no longer folds a constant whose only definition may not run
  (written under a condition, in a loop, block or rescue, or after an early
  exit): such a read now raises `NameError` as the interpreter does. Two
  reopenings of one class in one file no longer emit duplicate C++ class-body
  definitions.
