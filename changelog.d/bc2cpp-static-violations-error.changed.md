- bc2cpp's static type check now treats annotation and signature violations as errors: an annotation token the compiler
  ignores, an annotation or RBS signature with more parameters than its method, and an RBS signature that names a method
  or class the program lacks (TC1003/TC1004) fail `scripts/bc2cpp/type_check.rb` (exit 1) and the build when the
  signature directory is set. Contradictions (TC1001) were already errors. Comment-wins overrides (TC1006) stay warnings.
