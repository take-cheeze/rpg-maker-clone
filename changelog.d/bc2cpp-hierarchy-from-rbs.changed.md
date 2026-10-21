- **bc2cpp**: the loop-installer owner list (`LoopInstallers::CORE_OWNERS`) is now derived from the core class
  hierarchy in `sig/bc2cpp/declarations.rbs#core_hierarchy` instead of being typed out by hand. The derived set is
  the same nine names. Behavior is unchanged; the hand-copied hierarchy tables in `ir_type_feedback.rb` and the
  `ITERATORS` list stay as they were, because the RBS tables do not match them exactly.
