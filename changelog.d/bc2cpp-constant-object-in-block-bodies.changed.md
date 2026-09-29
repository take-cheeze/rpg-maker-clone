- bc2cpp resolves constant-receiver calls (module functions such as `LCF.field?`) inside
  inlined block bodies to direct calls, using the site index the other proofs already
  use; 41 fewer dynamic sends in the shipped build.
