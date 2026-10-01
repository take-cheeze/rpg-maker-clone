- **bc2cpp** reaches `===` and `is_a?`/`kind_of?` by direct C calls in closed worlds: receivers
  the bytecode proves (class constants, Integer constants, literals) skip dispatch, other
  `case/when` sites share one `bc2cpp_eqq` helper, and a non-class `is_a?` argument raises its
  TypeError in place. By-name `===` sends in the wio world drop from 577 to 2 and `is_a?`/`kind_of?`
  from 55 to 0 (ADR 0293, `scripts/bc2cpp_eqq_direct_check.rb`).
