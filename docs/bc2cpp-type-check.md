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
| TC1003 | error | a signature names a method or ivar class the program lacks (a stale signature) |
| TC1005 | error | an index (`x[i]`, `x[i] = v`) on a receiver that may be nil, with no nil check before it (ADR 0439) |
| TC1004 | error | an annotation token bc2cpp ignores (unknown class), a signature or annotation with more tokens than the method has parameters (fewer is fine: a prefix) |
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

## Signature files (RBS)

Put `.rbs` files under `sig/bc2cpp/` (or point `BC2CPP_SIG_DIRS` / `--sig DIR` at other directories). They feed the same
hints as the comments and are checked the same way (ADR 0413):

```rbs
module Game
  class Actor
    @items: Array[Game::Item]          # ivar element class (guarded hint)
    @hp: Integer                       # checked against the inference, not forced
    def initialize: (Integer hp, Symbol kind) -> void
    def target: (Game::Actor other) -> Game::Actor
    def items: () -> Array[Game::Item]
  end
end
```

Supported: classes/modules; `def` with required positional parameters and one overload; `@ivar: T`; `attr_reader` /
`attr_accessor name: T`; types `Integer`, `Symbol`, `Array`, `Hash`, `Array[C]`, `Hash[K, C]` and program classes.
Accepted without a hint (TC1005 note): optional / rest / keyword / block parameters, `T?`, unions, `untyped`, `void`,
`bool`, `self`, singleton methods, constants, aliases, mixins, visibility, other generics, a class the program does not
define. Errors (TC1002): parse errors, overloaded `def`, other declaration kinds. A comment wins over a signature
(TC1006); an unknown method is TC1003; a wrong parameter count TC1004. Both are errors (see ADR 0436): a stale or mis-sized annotation fails the check and the build, the same as a contradiction.

Loop: write the signature, run `type_check.rb` (contradictions are reported at the signature's line), fix them, then
enable the strict tier when it is available so a wrong signature fails loudly at run time instead of falling back.

## RBS output and Steep

`type_check.rb --emit-rbs DIR` writes the inferred types as RBS (ADR 0414), one file per class or module. Unknown types are
`untyped`; optional / rest / keyword parameters are `untyped`; every method accepts an optional block; CRuby's core RBS is
the base environment (classes it declares are not redeclared). The directory is not read as hints unless named in
`BC2CPP_SIG_DIRS`; read back, it reports nothing, and a wrong edit is a located TC1001.

Steep on the CRuby-loadable part, measured (Steep 2.1.0 installed with `gem install steep`; run it with
`ruby $(gem contents steep | grep exe/steep) check`, rbenv does not shim it here). Steep checks only paths inside the
Steepfile's directory, so symlink the sources next to it:

```
# Steepfile
target :lcf do
  signature "sig"                         # the --emit-rbs output
  check "mruby-lcf/mrblib"                # symlink or copy of the gem
  configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)
end
```

`mruby-lcf/mrblib` (7 files, 4657 lines) checks in about 7 seconds:

| Signatures | Steep errors |
| --- | --- |
| none | 1249 (668 methods in undeclared modules, 255 unknown constants, 948 no-method) |
| emitted by `type_check.rb --files mruby-lcf/mrblib/*.rb --emit-rbs sig` | 73 |

What remains: 47 `NoMethod` (mostly `LCF` module-level helpers and the native `cp932_to_utf8` / `utf8_to_cp932`, which
need native signatures; mruby core methods CRuby's RBS lacks need the same), 21 empty `[]` / `{}` literals that strict mode
wants annotated, 4 argument mismatches from `untyped`-vs-inferred unions, 1 overload. Getting this to zero needs
signatures for the engine's native classes and the mruby-only core methods (a hand-written or generated set per native
gem; not done here) and for the module-level helpers. Larger gems (mruby-rpg2k, mruby-rgss) additionally need the lcf and
rgss native classes declared, so they would stop at hundreds of `NoMethod` until then. Full mruby-core RBS is out of scope.
