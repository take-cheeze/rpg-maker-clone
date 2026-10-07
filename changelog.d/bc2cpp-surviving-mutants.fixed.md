- **bc2cpp** the two mutation checks that run only on `master` pushes
  (`bc2cpp_call_results_mutation_check.rb`, `bc2cpp_call_facts_mutation_check.rb`)
  report no surviving mutant again: the accessor "no class pool" mutant is
  killed by a reader whose setter the setter pools refuse, and the call-facts
  native-owner mutant by an Array method that is only natively defined.
