- Preserve proven collection result classes across nested core Ruby literal-block
  calls in bc2cpp, retaining lookup and block-exit exclusions and refusing
  recursive specializations. Audit Range's Array-or-nil numeric helper and
  superclass fallback to preserve `to_a` result classes.
