- **bc2cpp**: the escape analysis no longer assumes every native method keeps its arguments. A `NATIVE_ARG_OK`
  table audits `==`, `equal?`, `eql?`, `is_a?`, `kind_of?`, `instance_of?`, `key?` and `has_key?`: an argument
  they only compare or look up stays confined. A name is audited only while every `NATIVE_SRCS` registration of
  it sits in an audited file; other names and all receivers are unchanged.
