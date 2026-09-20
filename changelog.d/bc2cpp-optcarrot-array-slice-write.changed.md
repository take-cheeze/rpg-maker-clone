- **bc2cpp** lowers optcarrot's exact-Array slice writes to `mrb_ary_splice`
  behind runtime checks for the receiver and fixnum indices.
