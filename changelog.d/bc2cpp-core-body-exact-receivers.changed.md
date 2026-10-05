- **bc2cpp** proves literal and `*rest` receivers exact inside compiled mruby
  core bodies too (ADR 0359), removing about 40 by-name sends from the Wio build.
  Unlike the engine's own proofs the core-body ones are checked at run time: each
  site keeps one class test and its else is a `bc2cpp_guard_violation`
  (`BC2cppGuardViolation`, or an abort under `-DBC2CPP_NOMETHOD_VERIFY`).
  `scripts/bc2cpp_core_singleton_audit.rb` fails CI when mruby's own Ruby gains a
  singleton-making construct that is not reviewed. `BC2CPP_CORE_BODY_EXACT=0`
  turns it off.
