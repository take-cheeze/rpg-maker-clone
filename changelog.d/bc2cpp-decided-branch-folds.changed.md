- **bc2cpp** folds a conditional jump whose tested register the numeric flow already proves truthy, falsy or nil, instead of
  emitting a runtime test (57 of 2,544 engine tests). `BC2CPP_DECIDED_BRANCH=0` restores every test. See ADR 0532.
