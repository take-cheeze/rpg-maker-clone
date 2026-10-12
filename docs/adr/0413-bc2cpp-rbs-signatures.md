# 413. RBS signature files as a source of bc2cpp hints

Date: 2026-10-12

## Status

Accepted

## Context

The only way to give bc2cpp a type is a `# bc2cpp:` comment above a `def` (ADR 0210/0290/0380 guarded hints). Comments
cannot name ivars or constants, repeat the method's shape, or be read by other tools. RBS is the standard syntax for
this, and `rbs`/Steep/TypeProf and RBS-aware editors already read it.

## Decision

`tools/bc2cpp/rbs_signatures.rb` reads `.rbs` files and feeds the same three tables the comments fill
(Annotations, ClassAnnotations, ElementAnnotations) plus the ivar-class and element tables after the analysis, so every
consumer, the contradiction check and the strict-hint tier treat a signature exactly like the equivalent comment.

* Directories: `BC2CPP_SIG_DIRS` (path-separated; empty switches it off); default `sig/bc2cpp` when it exists. With no
  `.rbs` file nothing runs and the output is byte-identical. The inferred-type output of the type check is written
  elsewhere on purpose (a build must not read its own output back as hints).
* Parsing is the `rbs` gem (a bundled gem of the CRuby that runs the compiler tooling; mruby is not involved). Without
  it the diagnostic says to install it.
* Supported subset (docs/bc2cpp-type-check.md): classes/modules, `def name: (T a, ...) -> R` with required positional
  parameters and one overload, `@ivar: T`, `attr_reader/attr_accessor`. Types: `Integer`, `Symbol`, `Array`/`Hash`,
  `Array[C]`/`Hash[K, C]`, program classes. Everything else is accepted with a TC1005 note or, for overloads, parse
  errors and unknown declaration kinds, a TC1002 error at its own file:line:col. A build with a TC1002 error aborts; the
  type check reports it. Nothing is dropped silently.
* A comment wins over a signature naming the same slot (TC1006). A signature for a method the program lacks is TC1003,
  one with the wrong parameter count TC1004 (not used).
* Contradictions are located in the signature file. A declared ivar class fills an ivar the analysis left unknown; an
  inferred class is kept and a disagreement is TC1001. `@x: Integer` is checked but not forced (embedding needs a proof).
* A declared type is a hint, not a proof: it stays guarded, and is forced by the strict tier when that is enabled.

## Consequences

Signatures can be written once, checked against the inference with locations, and shared with other RBS tools. The
supported subset is deliberately small; unions, nilable types and block types give no hint yet.
