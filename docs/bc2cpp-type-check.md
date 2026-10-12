# bc2cpp type check

A report-only, TypeScript-like gradual check built on bc2cpp's own whole-program inference (ADR 0412). It never
changes generated code and never fails a build.

## Run it

```
MRBC=path/to/mrbc ruby scripts/bc2cpp/type_check.rb                 # the engine, text report
MRBC=... ruby scripts/bc2cpp/type_check.rb --format json --out tc.json
MRBC=... ruby scripts/bc2cpp/type_check.rb --format tsv  --out tc.tsv
MRBC=... ruby scripts/bc2cpp/type_check.rb --files app.rb lib/*.rb   # your own program (closed world)
ruby scripts/bc2cpp/type_check.rb --facts kept/facts.json --rows kept/rows.tsv   # re-render, no analysis
```

`--keep DIR` keeps `facts.json`, `rows.tsv` and `bc2cpp.stderr`. `--all` adds one info line per untyped item,
`--no-sends` skips the send ranking, `--what-if` estimates removable lines (slow), `--top N`, `--scope all` includes
the mruby core mrblib. The analysis takes the time of a build's analysis phase (minutes for the engine).

## Output

Diagnostics are `file:line:col: severity: message [CODE]`, sorted errors first, so an editor problem matcher
(`gcc`-style) reads them. Exit status is 1 only when there is an error.

| Code | Severity | Meaning |
| --- | --- | --- |
| TC1001 | error | a declared type disagrees with the inferred one (fixnum/symbol argument or return, class argument, class return) |
| TC1002 | error | a signature file could not be used |
| TC1004 | warning | an annotation token bc2cpp ignores (unknown class), or a parameter count that is not the method's |
| TC2001-3 | info (`--all`) | untyped parameter / return / ivar, with the reason |
| TC3001 | info | `suggestion #N`: a signature on this declaration would act on N by-name send lines |

The summary lists typed / untyped counts for parameters, returns, ivars and constants, the source of each type
(`annotation`, `inferred:call-sites`, `inferred:class-pool`, `inferred:return-analysis`, `inferred:ivar-layout`, ...) and
the reason buckets of what is untyped:

* parameters: `poly:N` (the name has N definitions), `dynamic-name`, `never-called`, `packed-caller`,
  `no_candidate:<rule>`, `dropped:<kinds>` (the receiver-proof reasons, ADR 0331);
* returns: the producers of the return sites no class could be named for, e.g. `send_result:foo(ruby)`,
  `send_result:to_s(native)`, `ivar:@x`, `param`, `element`, `unanalyzable:<why>`;
* ivars: `any` (stores disagree, inherent) or `opaque` plus the ADR 0382 bucket (`parameter`, `project_call`, ...), or
  `nil-or-unassigned`.

## Workflow

1. Run the check; read the top suggestions.
2. Add a hint above the `def` (`# bc2cpp: (Game::Actor, fixnum) -> Game::Actor`, `-> Array<Klass>`).
3. Re-run: a hint that contradicts the inference is a TC1001 error at the comment's line; an ignored token is TC1004.
4. A correct hint makes the parameter `annotation`-typed and its sends take a direct arm. Hints stay guarded (a failed
   guard falls back to the by-name send); forcing them is the strict-hint tier.

Note: with guarded hints the by-name line stays as the else arm, so the count of `bc2cpp_send` lines does not fall;
the ranking is where a type fact acts, and it is exact only for the lines counted.
