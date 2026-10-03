- **bc2cpp** `BC2CPP_RECEIVER_PROOF_REPORT=FILE` (ADR 0331) writes one row per engine send whose unproven receiver keeps
  a by-name line (the source of the receiver, why it has no class set, and what the line becomes when the receiver is forced
  to a class set, by a forked recompile), and `scripts/bc2cpp_receiver_proof_report.rb` aggregates it. It changes no
  generated code. Of the 1,970 engine sends that still dispatch by name, 1,783 have an unproven receiver; the best sound
  slice measured (an audited native result class plus dropping the `<native>` placeholder of a name no linked source
  defines) removes 22 by-name sends, below the cutoff of 30, so none was built.
