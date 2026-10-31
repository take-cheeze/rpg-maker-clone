# Direct Array key comparison in sort_by

The inline `sort_by` lowering can compare exact builtin Array keys through
`bc2cpp_sort_key_cmp` rather than entering `Array#<=>` through `mrb_cmp`.
The event renderer's `[y, x, id]` keys were the largest lookup target in the
[startup/gameplay survey](bc2cpp-lookup-survey.md).

Generation uses the existing `array_native_refusal('<=>')` proof. The complete
world must exclude Ruby and native replacements, hidden definitions, dynamic
installers, unresolved mixins and prepends that could change Array's method.
The providing core `array.c` must match its audited file digest, covering the
`mrb_ary_cmp` body and native registration. Any source drift declines the optimization.

The helper checks that the left key's runtime class is exactly builtin Array
and the right key is an Array. Other keys, subclasses and singleton-class
receivers retain `mrb_cmp`. On the direct path it mirrors the native identity,
element-order and length comparisons. Every element comparison still uses
`mrb_cmp`, preserving custom element methods, nested Array overrides,
incomparability and side effects. It reads the arrays' current lengths and
slots again after element calls, as the native implementation does.

This changes only key comparison. Key evaluation, decorated insertion sorting,
index tie-breaking, result construction and ArgumentError handling stay the
same. `BC2CPP_SORT_ARRAY_CMP=0` restores the original lowering for comparison.
It does not by itself remove the Array comparison method-table entry.

`scripts/bc2cpp/sort_array_cmp_check.rb` checks generation and refusal cases,
native body/binding drift, and interpreted-versus-compiled behavior for tuple
keys, mixed scalar keys, custom elements with GC, Array subclasses, nested
arrays, duplicate keys and incomparable values.

## Measured result

With the same startup-aware instrumented configuration and Nepheshel workload
as the baseline survey, all seven scenarios and 543 map runs pass. The only
installed owner/name whose gameplay lookup count changes is `Array#<=>`:

| Metric | Before | Direct key comparison |
| --- | ---: | ---: |
| `Array#<=>` gameplay lookups | 17,071,756 | 384 |
| All gameplay lookups, including probes/misses | 37,654,267 | 20,582,895 |
| Installed method-table entries | 1,071 | 1,071 |
| VM starts beyond initialization | 0 | 0 |

The direct path eliminates 17,071,372 lookups, reducing total gameplay lookup
traffic by **45.3%**. Remaining Array comparison lookups use paths outside
this shortcut. All 550 processes still match the 147-event initialization VM
baseline, and the registration proof reaches the same fixed point.

A separate local timing run used map 355, the map with the most baseline Array
comparison lookups, for 600 frames with observers disabled. Both binaries were
built with lookup/VM-counter support; the lookup callback was NULL and no
counter output was requested. After one warmup pair, five alternating pairs
had median elapsed times of **4.308 s before and 3.651 s after**: about **15.2%
less time** on this selected map. This is a headless, comparison-heavy workload,
not an estimate for all maps or device builds. The source proof/generation
work was running concurrently, so the paired samples describe this local run.
The original samples and reports are under
`build/bc2cpp-sort-array-cmp-20261101/`.
