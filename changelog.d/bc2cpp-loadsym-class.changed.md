- **bc2cpp knows a Symbol literal in a register.** A `LOADSYM` register now
  carries the Symbol class bit in the numeric flow (the bit a Symbol element
  of a frozen table already had), and a `kind_of` test against a class decides
  that bit exactly, so `x.is_a?(Integer)` on a value that may be a Symbol keeps
  the numeric proof of the Integer branch. The consumers of the numeric masks
  were audited in `docs/bc2cpp-symbol-class.md`; the new record is ADR 0429.
  Kill switch `BC2CPP_LOADSYM_CLASS=0`; `scripts/bc2cpp/loadsym_class_check.rb`
  covers it.
