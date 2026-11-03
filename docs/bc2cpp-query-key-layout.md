# Reaching-definition query keys

The reaching-definition answer cache keeps its existing 1,024-answer limit and
public copy/shared-result behavior. For valid instruction indices and
nonnegative integer registers, common query options are grouped into bounded
policies. Each policy records the exact state budget, canonical opaque-register
snapshot, and four Boolean options: move following, handler traversal, origin
transfers, and RAISEIF nil handling.

Only insertion of a retained answer creates a policy, and its identifier is the
current answer-cache size, which is below 1,024. The key is:

```text
(register * instruction_count + instruction_index) * 1024 + policy_id
```

The instruction index is within the fixed body length and the policy identifier
is below 1,024, so distinct retained queries cannot collide. Invalid indices,
negative or noninteger registers, and nonstandard option values keep the former
Array key path. Diagnostic queries and mutable opaque sets remain uncached.
Once the answer cache fills, neither new policies nor answers are retained.
`BC2CPP_IR_QUERY_KEYS=0` restores Array keys and the previous opaque-snapshot
behavior for comparison.

The existing IR fact checks compare cached results against fresh diagnostic
queries over every Boolean-option combination, several budgets, opaque sets,
registers, invalid indices, and cache saturation. Separate tests check policy
bounds and deeply frozen shared results. The code is host Ruby only; it does not
change target integer widths or generated runtime representations.

On the warm sealed Optcarrot compiler workload (Ruby 4.0.5), direct allocation
counts changed from 11,267,812 to 11,199,399: about 68,400 fewer objects (0.61%).
Array allocations fell from 4,267,197 to 4,196,451; policy maps added about 2,250
Hash allocations. Generated C++ was byte-for-byte identical. These counts include
compiler loading, analysis and emission; GC remained enabled and the native
NEWOBJ counter included allocations later collected. The source-scan cache was
warmed after each compiler-source change. These are allocation measurements,
not evidence of a runtime speedup or lower peak RSS. The profiling procedure is
in [compiler data profiling](bc2cpp-compiler-data-profile.md).
