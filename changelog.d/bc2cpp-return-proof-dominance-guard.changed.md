- `tools/bc2cpp/bc2cpp.rb`'s RETURN-site proofs (ARRAY_RETURN_PROOF,
  RETCLASS_SELF_CALL_SUPPORT) now accept a writer behind an unrelated jump
  target, as long as that write dominates the RETURN. Having only one writer
  is not enough, because the local's or argument's value at method entry is a
  second definition. The proofs now also refuse two unsound shapes the old
  guard let through: a local that a nested block reassigns, and a
  `.new`/`.dup`/accessor receiver that is assigned in both arms of a join.
  ARRAY_RETURN_PROOF 113 -> 131, RETCLASS 145 -> 182, CLASS_HINT 268 -> 273
  (the five `@background` ivars). Covered by the new
  `scripts/bc2cpp_return_join_check.rb`. See docs/adr/0198.
