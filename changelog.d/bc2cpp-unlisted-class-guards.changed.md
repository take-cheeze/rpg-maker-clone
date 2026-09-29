- bc2cpp: a closed-world guard chain that leaves out a definer class (arity, unclean body, mixin in
  the way) now guards that class with its own dispatching branch, so the remaining `else`
  is a proven-dead `bc2cpp_nomethod` (948 sites, ADR 0252; 716 new `NOMETHOD_REVIEWED` keys).
