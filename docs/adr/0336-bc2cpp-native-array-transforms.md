# 0336. bc2cpp: join audited native collection transformations with Ruby returns

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0335 proves compact and join only for exact Array receivers. The native bodies
also have useful result contracts when the input class is unknown, and the internal
__uniq result feeds Ruby Array#uniq. A name-wide fact must include every linked
native spelling and join all compiled Ruby returns. In particular File.join shares
Array#join's name, and Hash has Ruby compact and flatten implementations.

## Decision

Add complete-source audits for native compact, flatten and __uniq returning a base
Array, and for Array#join and File.join returning String. Pin Array-ext allocation
and transformation code, core Array allocation helpers, and core String helpers.
File's complete source accepts pristine and the project's MAXPATHLEN fallback patch.
Array compact/__uniq return the newly allocated Array after their helpers; flatten
returns the Array allocated by flatten_internal. No element-class fact is inferred.

Array join allocates a base String and appends converted values. File.join returns
an existing component on its single-component path, including a String subclass.
Require String subclass freedom whenever File.join is linked before using a
name-wide exact String contract. An exact Array's existing join proof still uses
its own allocation contract independently. Calls, conversions and their effects run
normally; this change only records successful result classes.

Join the native facts through the existing Ruby return fixpoint and visibility gates.
Ruby replacements or mixed returns widen the set. Uncompiled Hash compact/flatten
bodies withdraw their name-wide facts; native allocation alone cannot prove their
Ruby returns. Unknown linked native files, installers, aliases, method_missing,
singleton creation, missing/changed helpers and open worlds withdraw the proof.
Permit these audited names through the broader foreign-name candidate filter only
when the linked native and Ruby visibility audit succeeds. Keep the compiled-alias
refusal. Unlinked native or Ruby files in the broader scan do not redefine a linked
method; linked Ruby definitions outside the return registry still withdraw the fact.

BC2CPP_NATIVE_ARRAY_TRANSFORMS=0 withdraws the four new name-wide facts. The existing
native-class-results switch also disables them. The collection switch continues to
disable compact/join facts, preserving ADR 0335's control semantics.

## Consequences

The full Wio census remains at 2,844 cached sends, 190 ivar pools, 136 argument
pools, 923 nil-receiver helpers and 1,026 exact-index arms. The shipped C++ is
byte-identical with the new switch on or off and to ADR 0335 output (SHA-256
509ae942126c305f959688807748ad12a13f04382c50e836276c7ce308f2fa64).
The reviewed fallback list remains 2,931 keys / 4,186 sites. No extra dispatch
savings or runtime-speed gain is claimed; the prior follow-ups still remove 80
sites from the original 2,924. Fixtures with otherwise unknown input classes now
prove the __uniq result and the joined native join result, while the shipped
program's existing proofs and remaining unknown/mixed returns leave its output
unchanged.

The new check audits registrations, every full source pin, changed and missing
allocation helpers, Ruby overrides, outside Ruby, linked and unlinked native
registrations, aliases, method_missing, installers, String subclasses, open worlds
and kill switches. Full-core and 32-bit compiled/interpreted parity exercises Array
subclasses and File.join's preserved String subclass. Seven mutants plus an unmodified
control verify source, helper, unknown-native, switch and subclass boundaries.
The minimal core library lacks Array-ext, so the new runtime check uses full-core.
CI runs generated/audit/mutation checks in call-facts and runtime parity in the
int32 width job. Existing collection and native-class checks remain regression gates.

Native setter inputs, dynamic caller completeness and mutable element classes
remain separate proofs. Core Ruby methods whose unknown branches prevent the return
fixpoint from converging also need further analysis before these facts can help them.
