- **bc2cpp** treats a class-body `define_method(:name) { |a, b| ... }` whose block a `def` could have
  spelled (required parameters, no captured locals, no `return`/`yield`/`super`) as an ordinary method
  definition in a closed world, so calls to it are devirtualized and its body is compiled. Computed
  names, `send(:define_method)`, singleton installs and every other shape keep poisoning the name
  (ADR 0288, `scripts/bc2cpp_define_method_sites_check.rb`).
