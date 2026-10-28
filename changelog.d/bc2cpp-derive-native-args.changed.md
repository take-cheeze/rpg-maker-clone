- **bc2cpp derives native `mrb_int` arguments instead of reading a hand list.**
  `NATIVE_ARG_TARGETS`, 57 human-vetted `Owner#name` entries in
  `tools/bc2cpp/dispatch_targets.rb`, is gone. A compiled method's mandatory
  argument is now an `mrb_int` when its declaration says Integer and every
  call site passes a proven Fixnum there (ENTRY_ARG_CALLSITE_PROOF), so the
  entry wrapper's conversion never meets anything else. Symbol positions stay
  boxed: no call-site proof covers them. The closed build retypes 15 methods;
  of the 57 listed, 43 have a call site the proof cannot show passes a Fixnum,
  and 4 have proven positions their declaration does not call Integer. The
  generation's `== native arguments (NATIVE_ARGS) ==` diagnostic lists them,
  and `scripts/bc2cpp/native_args_check.rb` checks the rule.
