- bc2cpp now emits one shared dynamic fallback after native type-tag checks,
  including `to_s` and `to_i`, instead of duplicating it in each direct-call
  branch.
