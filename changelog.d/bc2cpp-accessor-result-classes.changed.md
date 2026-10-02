- **bc2cpp** (ADR 0309): an `attr_reader` now returns the class set of the ivar slot it reads, so the result
  of `holder.thing` is an exact receiver for the next send, and an Array the exact-class flow proves takes
  `push`/`<<` and the TYPED call of a core class's body with no class test. On the wio closed world this removes
  63 rpg2k by-name sends (70 across all gems) and 255 sites that can reach by-name dispatch, with no
  relocation. `BC2CPP_RETURN_ACCESSORS=0` and `BC2CPP_EXACT_CORE_ARMS=0` restore the old output byte for
  byte. New diagnostic `BC2CPP_SEND_ROOT_REPORT` with `scripts/bc2cpp_send_root_report.rb` ranks the
  producers behind the by-name sends; checks `scripts/bc2cpp_call_results_check.rb` and
  `scripts/bc2cpp_call_results_mutation_check.rb`.
