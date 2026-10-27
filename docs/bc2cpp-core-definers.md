# Ruby definers outside the registry

bc2cpp's whole-program registry lists each method name's definitions. A name with
exactly one listed definition is MONO, and a call site may call that body
directly, trusting the name alone.

Some Ruby definitions of a name are left out of the registry:

- core bodies that stay interpreted (`CoreMethods` refusals, Fiber/lambda
  bodies), and guarded or native-named core bodies that are compiled but kept
  out of the registry (CORE_VISIBILITY, `HIDDEN` in the log);
- core aliases (`alias map collect` in `Enumerable`), which never become
  registry entries;
- Ruby the run does not compile: outside and foreign mrblib, plus the mrblib of
  every linked gem that the run does not compile.

If the program also defines such a name, for example `map` on an `Array`
subclass only, the registry used to hold one definition. Every `a.map { }` on a
plain Array was then compiled as a direct call to the subclass body.

`CoreDefs.add_unseen_placeholders!` (CORE_UNSEEN_DEFINERS) adds the `<native>`
placeholder to every such name that the registry already lists. A `<native>`
placeholder stands for definers that the compiler cannot call directly, so the
name stays POLY. Receiver-class proofs (LEXICAL_SELF, CHA_SELF, typed and
owner-checked calls) still pick the program body when the receiver is known.
The log lists the affected names under `== Ruby definers outside the registry`
as `FLIP :name`.

A name the registry does not list gets no placeholder. Its core-only proofs
(COLLECT_DIRECT, GUARDED_BLOCK_INLINE, BLOCK_CORE_DIRECT, ...) are unchanged.

`scripts/bc2cpp/core_definer_mono_check.rb` covers this. It checks
subclass-only `map`, `collect`, `reject`, `each_with_index`, `sort_by` and
`Hash#each_pair`, and a mixed-in `select`. It runs them with the core mrblib
compiled and with it outside.
