# bc2cpp foreign method scanning

`ClosedWorld#outside_ruby_definer_paths` and `#outside_ruby_paths_defining`
share `#outside_ruby_path_method_names`, which reads and scans each foreign
Ruby file once per `ClosedWorld` instance. The former previously bypassed
that memo, repeating the Prism tree walk and conservative regex scans for
every distinct method name, even though the parse tree itself was cached.

This reuses the existing per-world cache: source inputs remain fixed during
one world's analysis, and a new world reads current contents. Definition
collection, path ordering, duplicate paths and absent-name results retain
their previous behavior.

A local CRuby 3.4.9 (historical; the bc2cpp jobs now use Ruby 4.0.5) benchmark queried the first 300 sorted method names from
39 mruby core and core-gem Ruby files. Each of three alternating baseline and
patched runs used a fresh world and cleared `RubyParseCache` before querying
`outside_ruby_definer_paths`. Baseline times were 2.659, 2.627 and 2.529
seconds; patched times were 0.024, 0.027 and 0.026 seconds. The marshalled
query results had identical SHA-256 hashes. This measures the query path,
not total generator or generated-game performance.

`scripts/bc2cpp/ruby_parse_cache_check.rb` checks both query families against
uncached scans, including multiple definitions, accessor names, absent names,
path ordering and duplicates. It counts file scans to catch repeated work
and checks that a new world sees rewritten sources.

Parser reuse assertions isolate the surrounding disk scan cache so a warm scan
cannot bypass the parser under test. Validate cache checks with both cold and
warm surrounding state.

## Symbol dispatch inside visitors

`ForeignDefNames` and `HiddenRubyOwnerScan` compare Prism call names directly as
Symbols against fixed installer, eval, mixin and reflective-send vocabularies.
Prism already supplies these Symbols, so an ordinary call needs no temporary
String merely to decide whether it can define a method. Collected method names
remain Strings. Reflective send targets also stay text comparisons, avoiding
interning arbitrary source literals or changing scanner output APIs.

A Ruby 4.0.5 probe parsed 41 real foreign mrblib files once, warmed both visitors,
then measured 20 complete visitor passes with `GC.stat(:total_allocated_objects)`.
Parser work and disk caches were outside the measurement:

| Visitor | Original allocations | Symbol dispatch allocations | Original seconds | Symbol dispatch seconds |
| --- | ---: | ---: | ---: | ---: |
| `ForeignDefNames` | 54,433 | 10,366 | 0.0273 | 0.0199 |
| `HiddenRubyOwnerScan` | 96,532 | 52,934 | 0.0255 | 0.0231 |

Both visitors produced identical outputs to their original implementations on
all 41 files. These measurements cover AST visitors, not total compiler or game
runtime performance. `ruby_parse_cache_check.rb` additionally covers all accessor
spellings, aliases, literal definers, String and Symbol reflective targets,
forwarded mixins, and computed instance/singleton definers.

## Owner-scoped hidden definitions (ESCAPE_ANALYSIS)

`foreign_method_names` gives only names, so a name that an interpreted mrblib
defines anywhere (`initialize` in `Exception`, `Set`, `StringIO`, ...) was
invisible to every class, and every `new` escaped. `foreign_method_owners`
(`tools/bc2cpp/native_names.rb`) also records the lexical owner of each plain
`def` in a class body or at top level. `EscapeAnalysis::World#defs_for` then
treats such a name as unknown only for receivers whose ancestry has that owner,
compared by last segment (an over-approximation). `defs_named`, which has no
receiver class, still refuses the name.

Refused for every name, because the owner or the name cannot be attributed:

- a def in a block, a module, a singleton class (`class << self`), a `def self.x`
  or another def's body;
- an alias, an `attr_*` or a literal `define_method` (name-level, as before);
- a computed-name definer outside a plain class body, a string or block-less
  eval, a send of a definer name, and a non-constant `include`/`prepend`/`extend`
  outside a forwarding `def include`;
- a file the parser refuses.

A computed-name definer in a plain class body is a wild owner: every name is
relevant on that class. A hidden `include M` of a compiled module M refuses each
name M defines. A hidden owner the tables cannot place (a hidden subclass) is
relevant to a receiver set, but not to an exact receiver.

`BC2CPP_ESCAPE_REPORT` writes each site's verdict. Zero-argument `new` (`SEND0`)
is a `new` site too, so its constructor is checked like the others.
