- **Frozen string literals**: a file with `# frozen_string_literal: true` now
  compiles its plain string literals to frozen Strings, as CRuby does, on the
  interpreter and in bc2cpp-compiled code alike. A literal is one persistent
  object per VM, so `equal?` holds across calls, mutation raises `FrozenError`,
  and files without the comment are unchanged. Covered by
  `scripts/bc2cpp/frozen_literal_persist_check.rb`; see
  `docs/frozen-string-literals.md` and ADR 0546.
