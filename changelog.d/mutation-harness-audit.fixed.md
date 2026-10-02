- **bc2cpp mutation checks** can no longer pass vacuously. Every harness now runs an unmutated control in a
  tree with the repository layout (four of them had copied the generator to `/tmp`, where the closed world is
  empty), proves it reads the same closed world as the real tool, and separates a kill by the intended
  assertion from a kill by a crash or build failure. Fixture runs carry a runtime probe that fails a
  compiled-versus-interpreted leg whose compiled VM never dispatched into compiled code.
  `scripts/bc2cpp_mutation_harness_check.rb` pins this with deliberately broken harnesses.
