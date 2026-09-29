- **bc2cpp** and the RPG2k/LCF/RGSS runtime treat "should not happen" paths as
  errors (ADR 0262): a generated function that falls off its end and a
  closed-world `bc2cpp_nomethod` whose proof turns out false now raise a
  `RuntimeError` naming the method or class and method; the outside-source
  readers raise on an unreadable file and report a missing one once on stderr;
  the constant-proof analysis raises on an unknown kind or opcode. In the
  mrblib, launcher-constant probes rescue only `NameError`, every remaining
  broad `rescue` reports to `$stderr` (or `RGSS.warn_once` in per-frame code),
  and the 14 `rescue` modifiers on record reads are gone.
