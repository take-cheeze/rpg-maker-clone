- **bc2cpp**: `public :name` / `private :name` / `protected :name` in a class
  body no longer counts as a dynamic mention of `name`, so the method keeps its
  call-site proofs (argument class pools, numeric argument proofs).
  `BC2CPP_VISIBILITY_LITERALS=0` restores the old rule.
