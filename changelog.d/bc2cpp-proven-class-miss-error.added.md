- bc2cpp closed-world builds now fail on a send whose receiver class is proven
  (a fresh `Klass.new`, an Array/Hash/String literal, `self` in a declared
  class, a class constant) when nothing in that class's chain answers the name
  and no `method_missing`, `respond_to?` probe or `rescue` guards it, unless
  the site is listed in `tools/bc2cpp/proven_miss_reviewed.rb` (ADR 0275). The
  list is empty today. `scripts/bc2cpp_proven_miss_check.rb` and
  `scripts/bc2cpp_proven_miss_update.rb` are the check and the regenerator.
