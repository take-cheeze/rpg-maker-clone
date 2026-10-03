# 0333. bc2cpp: join audited native class results and discard absent placeholders

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0331 measured a native-result prototype but did not ship it under its original 30-site cutoff. ADR 0332
subsequently removed 43 cached sends through audited native ivar families. The requested follow-up explores the
remaining receiver-proof candidates, including gains below that original cutoff. A native registry placeholder
can still spoil a return join even when the actual build links no definition with that name. Actual native
Array results also become unknown, preventing their callers and subsequent ivar stores from carrying a class.

## Decision

Add `NativeClassResults`, a complete-byte source audit of every actual linked native source spelling an audited
name. A successful native return contributes a class to the existing name-wide Ruby/native return join; it never
changes or skips the original call. Unmodelled linked sources, changed digests, outside Ruby, aliases, unknown
installers, method_missing and singleton creation withdraw the relevant proof. The broader `NATIVE_SRCS` census
is not evidence that a gem is linked: the audit uses the actual closed-world build's native paths.

| Name | Audited native contract |
| --- | --- |
| `keys` | Hash allocates a base Array. |
| `values` | Hash and Struct allocate base Arrays. |
| `bytes`, `split` | String allocates base Arrays on every successful path. |
| `members` | Struct instance/class methods copy members into a base Array. |
| `to_a` | Array returns itself only for exact Array, otherwise duplicates into a base Array; Struct allocates one. |
| `parameters` | Proc allocates Arrays; Method allocates one or delegates to Proc's audited body. |
| `snap_to_bitmap` | Graphics returns RGSS::Bitmap **or nil**, including disabled/failed snapshot paths. |

The pins cover the helper bodies, registrations, conditionals and macros in the full source files. Proc's pristine
and project-patched sources are both audited: the patch replaces access to irep local-variable metadata without
changing the allocated result class. Method's fact requires its Proc delegate among the audited linked sources.
A rebound RGSS::Bitmap constant withdraws the snapshot fact. Exception paths do not become successful results.
OnigMatchData's `to_a` is deliberately excluded: its mutable cached value needs a different invariant, so linking
its implementation withdraws the name-wide Array fact.

An exact built-in receiver can additionally prove Array#to_a and String#bytes through the existing
`NativeCoreDirect` registration/lookup audit, even when another Ruby definition widens the name-wide join.
This uses the exact-class oracle, rather than numeric masks, and retains singleton and override withdrawal.

`return_table_definitions` removes a `<native>` placeholder only if the complete closed-world scan proves the
name fully visible, with no actual native or outside definition. It filters the numeric/class return joins only;
the dispatch registry is unchanged. `BC2CPP_NATIVE_CLASS_RESULTS=0` disables new native class results and
`BC2CPP_ABSENT_NATIVE_RETURNS=0` preserves absent placeholders.

### Measurement

Full Wio coverage on master `43d4d462`, switches off versus on on this tree:

| Measure | Both off | Native results only | Absent placeholders only | Both on |
| --- | ---: | ---: | ---: | ---: |
| Cached by-name sends / with-block sites | 2,881 | 2,872 | 2,874 | 2,865 |
| Class ivar pools | 187 | — | — | 188 |
| Class argument pools | 117 | — | — | 120 |
| INDEX_EXACT arms | 1,000 | — | — | 1,025 |
| NILABLE_RECEIVER sites | 918 | — | — | 918 |

The combined gain is 16 cached sites. Four obsolete reviewed `dispose` fallbacks disappear in RGSS effect_probe,
frame_mean and Scene::Map's captured-transition drawing/release methods. No new no-method fallback is introduced.
With both switches off, shipped C++ is byte-identical to master (SHA-256
`76297de0b66bf86951120dd05c860a6368f6aa4fd5e873810b7d9b068c243ca1`).
Together ADRs 0332 and 0333 remove 59 cached sites, from 2,924 to 2,865. This is a generated dispatch-site count,
not a runtime-speed claim. The original prototype's 22-site estimate is not the final gain after the ivar follow-up
and the complete nullable snapshot contract.

### Remaining candidate audit

A shared-name argument-pool prototype joined every visible caller into multiple same-arity mandatory Ruby bodies.
It removed **zero** additional cached sites. Native setter entries, outside tokens and dynamic setter names still
prevent caller completeness for `contents=` and `bitmap=`. Proving these requires receiver-specific dispatch and
installer/caller coverage; arbitrarily restricting their accepted values would change game behavior.

Adding audited Window `width`/`height` ivar scopes also removed **zero** sites. The prototype is not shipped.
A broader native `to_s` audit remained blocked by additional linked definitions (including Fiber), Struct's Ruby
alias to native inspect, and foreign/alias visibility. Exact String would additionally require handling String
subclasses and OnigMatchData's possible nil result after its matched String is shortened. The partial audit is not
shipped; a source whitelist alone cannot bypass these conditions.

The ADR 0331 floor probes are ceilings with overlapping sites, not promises that all sites are optimizable.
Unknown stores, dynamic names, collection elements and arbitrary native setter inputs need further independent
proofs. This follow-up covers the identified feasible native-result slice and records the failed candidates; it
makes no claim to enumerate every future compiler optimization.

## Consequences

More collection operations and stores carry their actual result class without assuming receivers or erasing Ruby
returns. Source pins deliberately withdraw on any byte change, including comments. Refresh them only after
reviewing the native contract and rerunning the withdrawal, mutation and runtime checks.

`scripts/bc2cpp_native_class_results_check.rb` covers every pin, unknown and changed sources, Method delegation,
nullable snapshots, constant rebinding, mixed Ruby/native returns, outside definitions, linked versus unlinked
native registrations, aliases, installers, method_missing, open worlds and both switches. Runtime fixtures compare
compiled and interpreted outcomes on full-core and core-only mruby, including a Ruby result of another class.
The mutation check kills eight mutants plus an unmodified control. CI runs these in `call-facts` and runs runtime
parity on 32-bit mrb_int in `bc2cpp-width (int32)`. `NCR_FULL_ONLY=1` avoids accidentally linking the separately
built 64-bit host core library in that width job.
