- bc2cpp: by-name sends whose answering classes the closed world can all name
  (core, native, mrblib and program definitions) become a call checked against
  that list, with an owner-violation error for an unseen definer. RGSS
  constructors pick their declared overload at the call site
  (`sig/bc2cpp/declarations.rbs#rgss_constructors`, audited against the C source), and
  `new` on a class method's `self` constructs directly when the class has no
  unknown subclass (ADR 0468).
