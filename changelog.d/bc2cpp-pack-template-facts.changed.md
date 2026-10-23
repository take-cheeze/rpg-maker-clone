- **bc2cpp** escape analysis: the template argument of `Array#pack` and `String#unpack` is now proven
  kept by no native (`NATIVE_ARG_OK`, `pack.c`), so a String template no longer escapes at those sends.
  Only an exact String qualifies. The shipped C++ is unchanged; the escape report shows 23 fewer
  `send_argument` verdicts on String creation sites. Check `scripts/bc2cpp/send_arg_facts_check.rb`.
