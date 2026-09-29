- bc2cpp: a `self` call inside a declared class's instance method no longer treats `def self.x`/`class << self`
  definers as possible answers (ADR 0255): 74 `term` sends become proven-dead `bc2cpp_nomethod`
  (31 new reviewed keys).
