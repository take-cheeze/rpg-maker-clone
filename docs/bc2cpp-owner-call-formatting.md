# Owner-call formatting allocations

Owner calls name a proven list of classes in `BC2CPP_OWNERS(...)`. Repeated
sites often use the same owner list. The formatter builds its quoted names
once per deeply immutable list and appends each call's argument expressions
directly to its output buffer, avoiding temporary `map` arrays and quoted-name
strings at every site.

The cache belongs to one `CodeGen` instance, uses list identity, and holds at
most 2,048 entries. Owner-set decisions retain frozen snapshots of their
names. Mutable lists, including frozen arrays with mutable String members,
are formatted without caching. A cached string is itself frozen, so neither
a caller nor another generator can change a later call's output. Dispatch
proofs, owner ordering, argument limits, and generated C++ bytes are unchanged.

The formatting cases in `scripts/bc2cpp/outside_owner_call_check.rb` compare
ordinary calls, block calls, splats and helper rewrites with the prior output,
including zero, one and sixteen arguments. They also exercise mutation,
snapshot ownership, per-generator isolation and the cache cap. The existing
fixture continues to check owner-call selection and refusal conditions.

A native `RUBY_INTERNAL_EVENT_NEWOBJ` counter measured 10,000 repeated ordinary
calls using one frozen sixteen-owner list and two arguments, after warming the
format cache:

| Object type | Prior formatter | Cached/appending formatter |
| --- | ---: | ---: |
| Array | 20,000 | 0 |
| String | 280,000 | 80,000 |

These are allocation counts for repeated formatting, including objects later
collected by GC. They do not establish a whole-compiler time or peak-memory
improvement. The compiler allocation profile that selected this work attributed
about 1.9% of warm sealed Optcarrot allocation samples to
`outside_owner_call_line` and its callees; see
[compiler profiling](bc2cpp-compiler-data-profile.md) for the workload and
measurement constraints.
