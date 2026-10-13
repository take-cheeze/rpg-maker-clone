- **bc2cpp** (ADR 0423): a block-form `class_eval` / `module_eval` / `instance_eval` no longer makes the whole world
  unresolved for constant reads. Only a string argument evaluates code, so only that form (and a splatted or keyword
  argument that may carry one) keeps the world unresolved, as ADR 0423 states. The nightly `core-exact-direct` shard
  passes again: `Enumerable#max`/`min` in the mruby core are compiled direct calls. Checks
  `scripts/bc2cpp/lexical_const_check.rb`, `scripts/bc2cpp/core_exact_direct_check.rb`.
