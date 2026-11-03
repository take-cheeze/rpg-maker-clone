# Reusing generated identifiers

The code generator repeatedly derives C++ names from the same owner, method
and field names. `sanitize` already memoizes escaped strings, but interpolating
`"owner_method"` or adding an ivar suffix before that lookup still creates a
new String on every call. Derived-name caches move the lookup ahead of that
formatting work.

`cpp_name` looks up owner and method contents separately, avoiding a temporary
pair Array or concatenated key. Its per-owner method tables are immutable;
adding a result replaces the table so a discarded compilation probe's shallow
state rollback restores both entries and their count. Other identifier
families each have their own content-keyed cache. Every additional derived-name
cache holds at most 4,096 results and falls back to ordinary formatting at the
cap. Ruby Hash String keys snapshot mutable inputs, so later caller mutation
does not corrupt retained keys. Results, including lexical path segments,
are frozen because they are shared.

Struct and data-type names resolve `embed_storage_owner` **before** looking up
the derived name. A class folded into another storage family therefore uses
that family's name even if the same generator previously named the class's own
storage. Changing or removing an embedding family cannot return a stale name.

Owner-class helper spellings live in their existing registration slots. Each
slot still receives its index in the same order, and probe rollback still
controls which slots survive. Caching its immutable spelling adds no second
registration table or numbering scheme. These slots retain their original
registration lifetime and are not subject to the optional formatting-cache cap.

`name_strings_check.rb` covers mangling bytes, operator method names, equal but
distinct input Strings, caller mutation, separate identifier namespaces,
embedding-family changes, independent generator numbering, probe rollback and
cache limits. Existing SETCONST, lexical lookup and embedding-family fixtures
exercise the identifiers in emitted C++ and in native interpreted/compiled runs.

## Allocation measurement

A native `RUBY_INTERNAL_EVENT_NEWOBJ` counter measured 10,000 repeated hits for
each function on Ruby 4.0.5 after warming both implementations. Outputs were
equal. The prior functions use the same memoized sanitizer, so the comparison
isolates work still done around its lookup:

| Function | Prior String allocations | Prior Array allocations | Cached-hit allocations |
| --- | ---: | ---: | ---: |
| `cpp_name` | 10,000 | 0 | 0 |
| `struct_name` | 10,000 | 0 | 0 |
| `type_var` | 10,000 | 0 | 0 |
| `ivar_field_name` | 10,000 | 0 | 0 |
| `lexical_scope_path` | 60,000 | 10,000 | 0 |
| `owner_class_fn_name` | 20,000 | 0 | 0 |

The workload repeatedly names `Game::Actor`, its `[]=` method and `@value`
field, and resolves `Game::Actor.singleton` for lexical lookup. Counts include
objects later collected by GC. Cache misses retain additional keys and results;
this hit-only measurement establishes neither a whole-compiler speedup nor a
peak-memory reduction. See [compiler profiling](bc2cpp-compiler-data-profile.md)
for complete-compilation measurement practices.
