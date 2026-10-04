# 0349. Specialize core Ruby results with fixed positional arguments

Date: 2026-10-05

## Status

Accepted

## Context

The core Ruby result oracle previously accepted only zero-argument calls. It
therefore lost collection results from methods such as each_with_object and
drop, even when the caller knew the memo's class or the method allocated an
Array independently of its arguments.

## Decision

Accept fixed positional calls when the selected bytecode has exactly the same
number of mandatory arguments and no optional, rest, trailing or keyword
parameters. Seed its argument registers with the caller's flow masks. Locate
the callee block register and the caller literal block after the arguments.

Include argument masks in specialization recursion keys and receiver-independent
result-cache keys. A body reads only these input masks and audited core facts;
the caller's existing flow invalidation handles changes to its input facts.
Retain the closed-world lookup, source visibility, installer, captured-write and
block-exit exclusions. An unresolved receiver still requires every possible
answering definition to produce a modelled result.

`BC2CPP_CORE_RUBY_POSITIONAL_RESULTS=0` disables argument-taking result proofs.
Generated and mutation checks cover separate Array/Hash/unknown/nil memos,
cache isolation, caller breaks, forwarded blocks, arity, optional/rest/keyword
signatures, captured writes and method replacements. Interpreter parity covers
normal calls, replacements and the switch.

## Consequences

Collection memo results retain their exact classes through subsequent calls.
Argument-independent allocation results are also available from fixed-argument
core methods. Optional and variadic calling conventions remain unmodelled.
These result facts do not bypass the original call or its argument errors.

Against cc54eee0, the Wio census with the positional switch off/on reports
2,772/2,769 cached sends. Generic POLY sites remain 897 and compiled entry points
remain 3,056. These static counts include guarded fallback sites and do not
measure runtime frequency or speed.
