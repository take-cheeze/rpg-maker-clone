# 0487. Predicates return bool and conversion methods are checked at build time

Date: 2026-10-17

## Status

Accepted

## Context

A method whose name ends in `?` is a predicate, and the language does not enforce that it returns `bool`. Many program
predicates return `@x || @y` or an `if` without an `else`, so a caller that relies on the convention can be wrong without
any error. The conversion methods the language calls (`to_s` for interpolation, `to_str`, `to_int`, `to_ary`,
`to_hash`) have the same gap: mruby checks the result of `to_int` and friends, and falls back for `to_s`.

The compiler already declares return types as runtime-checked hints (`%a{bc2cpp:hint}`, ADR 0455). A hint is a runtime
error, not a build error, so a predicate rule enforced only through hints would not be a rule on the build.

## Decision

- A method ending in `?` must return `bool`. `PredicateReturns` (tools/bc2cpp/predicate_returns.rb) proves it from the
  source: the literals `true` and `false`, `&&` and `||` of bool values, an `if`, `unless`, `case` or `begin` whose arms
  are all bool (with an `else`), and calls to the built-in predicates in `BOOL_CALLS`. A `?` call that is not in that
  list is not a proof. A predicate that cannot be proven is a build error, unless it is listed in
  `scripts/bc2cpp/predicate_whitelist.txt`. The gate runs before the Ruby sources are compiled. A whitelist entry whose
  file is compiled but whose predicate now proves bool is reported, so the list shrinks.
- `to_s`, `to_str`, `to_int`, `to_ary` and `to_hash` take only optional positional parameters. A required, rest or keyword
  parameter is a build error (`ConversionReturns`, tools/bc2cpp/conversion_returns.rb). Their returns are declared as
  runtime-checked hints in a generated signature file, so a value of the wrong class raises `BC2cppHintViolation` when it
  runs, and a return the compiler proves costs no check.
- Their optional parameters are declared `?T`, T the class of a literal default (`?untyped` otherwise). The checker
  gives an optional parameter no hint (TC1005), so this declaration is documentation until optional positions are
  checked at call sites (ADR 0456 covers only required ones).

## Consequences

- A program predicate that does not return bool stops the build until it returns bool or is whitelisted. The whitelist
  is the list of known exceptions and is part of the review.
- `to_s` returning a non-String raises at run time, where mruby would fall back to `any_to_s`. This is a deliberate
  difference: the program is required to return a String from `to_s`.
- The proof is by name for the built-in predicates. A program that redefines a core predicate such as `nil?` is not
  checked against its own body; the closed world does not allow redefining core methods.
- The gate reads every `mrblib` and gem Ruby source, including mruby's core gems under `3rd/mruby/mrbgems`, so the
  whitelist covers those too.
