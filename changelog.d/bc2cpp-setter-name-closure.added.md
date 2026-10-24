- **bc2cpp**: setter pools (attr_writer/attr_accessor ivars and setter
  arguments) become unguarded proofs when the program can make no value naming
  a setter it does not spell (SETTER_NAME_CLOSURE). On the closed world this
  removes 9 by-name sends and 114 runtime class tests from the generated C++.
  `BC2CPP_SETTER_NAME_CLOSURE=0` restores the old rule; checked by
  `scripts/bc2cpp/setter_name_closure_check.rb`.
