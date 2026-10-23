# Promoting candidate RBS

`type_check.rb` writes candidate RBS (`--emit-rbs DIR` and `--emit-rbs-suggestions DIR`, see
[the type-check workflow](bc2cpp-type-check.md) and [IR feedback](bc2cpp-ir-feedback.md)). Candidates are never
read as contracts and never edit `sig/bc2cpp`. `scripts/bc2cpp/promote_candidates.rb` is the reviewed step that
copies an accepted candidate into a signature file.

```sh
# Dry run (the default): prints the members it would add, the skipped ones and a unified diff. Writes nothing.
ruby scripts/bc2cpp/promote_candidates.rb coverage/rbs-suggestions

# Apply the diff, then parse the result with RBS (exit 1 if it no longer parses).
ruby scripts/bc2cpp/promote_candidates.rb --write coverage/rbs-suggestions

# Another target (default: sig/bc2cpp/declarations.rbs).
ruby scripts/bc2cpp/promote_candidates.rb --target FILE CANDIDATE_DIR

# Skip the constants DECLARED_CONSTANT_CHECK rejects (see "Constants" below).
ruby scripts/bc2cpp/promote_candidates.rb --proofs PROOFS.json CANDIDATE_DIR
```

Review the dry-run diff before `--write`; the write is the only step that changes a file.

## What is added

- Only methods, ivars and constants the target does not declare yet. A name the target declares in any
  section, the base section included, is left alone. An existing declaration is never changed or removed.
- Members are appended after the last section, under `# ---- promoted candidates: DIR`, where DIR is the
  candidate directory's name. Each candidate file's leading comment is carried over as the provenance of its
  block, minus any line with a date; a candidate with no leading comment gets `# candidate: DIR/PATH`.
- A new class is written with its candidate superclass. A class the target already declares is reopened without
  a superclass clause.

## Constants and the TC1011 proof

A candidate constant (`NAME: Integer`, `NAME: Array[T]`, `NAME: Klass`) becomes a declared constant once promoted,
and then DECLARED_CONSTANT_CHECK checks its assignment at every bind. A declared `Integer` whose assignment the proof
does not cover is a build error (TC1011, "the assigned value is not a proven Fixnum expression"). A promotion that
adds such a constant would break the next build, so `--proofs` keeps it out.

The verdicts come from the check itself, not from a second copy of the proof. bc2cpp runs
`DeclaredConstants.verdicts` on the candidate directory's constants, as if they were declared, and writes one JSON
file:

```sh
MRBC=path/to/mrbc BC2CPP_CONSTANT_PROOF_CANDIDATES=coverage/rbs-suggestions \
  BC2CPP_CONSTANT_PROOF_OUT=coverage/proofs.json ruby scripts/bc2cpp/type_check.rb
ruby scripts/bc2cpp/promote_candidates.rb --proofs coverage/proofs.json coverage/rbs-suggestions
```

The file is `{"version": 1, "candidates": DIR, "verdicts": {NAME: null | TC1011 message}}`. `null` means the check
accepts the constant. The program's own diagnostics are unchanged: the probe only reads the candidates' entries.

With `--proofs`, a constant is skipped when:

- its verdict is a TC1011 message (listed as `TC1011: ...`);
- it is an `Integer` or `Array` constant with no verdict (listed as `no proof fact`), since the check would read it
  but the file does not cover it.

Other constant types are not read by the check and are promoted as before. Without `--proofs` the dry run says that
constants are not checked against TC1011. A proofs file that cannot be read, has another version, or was written for
another directory is refused (exit 1, nothing written).

## What is skipped (and listed)

- A member whose required parameter, required or optional keyword, or return type is `untyped`, or that names a
  type the target does not declare. The emitter writes `untyped` for optional, rest and block parts of every
  method, so those parts are not checked.
- A new class whose superclass the target does not declare. The whole class is skipped.
- A class or module whose kind (`class` or `module`) differs from the target's, or whose superclass differs from
  the target's declared superclass. The whole class is skipped.

"Declares" means the target file or CRuby's core RBS. A type such as `Integer` or `String` is therefore usable
without a line in the target.

## Refusals

The run stops with exit 1 and writes nothing when:

- the target has no `# ---- block_types.rbs` line, so its base section cannot be told apart;
- the target does not parse with RBS;
- a candidate file does not parse, or carries a base-generator line (`# bc2cpp-native:`, `# Base RBS`,
  `# Native base RBS`, `# ---- base stubs`). Such a candidate belongs to the base section, which
  `scripts/bc2cpp/base_section_check.rb` owns (see [base RBS](bc2cpp-base-rbs.md)).

The promoted text is parsed before it is written. After `--write`, the file on disk is parsed again and a
failure exits 1.

## Checks

`scripts/bc2cpp/promote_candidates_check.rb` is a host-only fixture check. It covers the dry run writing
nothing, existing declarations staying as they are, untyped and undeclared members being skipped, the
base-section and no-marker refusals, the unparseable-target refusal, the write's result (append-only, base
section byte-identical, parses again), a second write changing nothing, and the `--proofs` gate: a TC1011 verdict
and a missing Integer or Array verdict are skipped, other constants are not gated, a bad proofs file is refused,
and the write leaves the target unchanged on refusal. It needs neither `mrbc` nor the closed build.

`DeclaredConstants.verdicts` is a thin wrapper over the declared-constant check, whose behavior
`scripts/bc2cpp/constant_proofs_check.rb` covers (it needs `mrbc`). The wrapper itself has no fixture of its own.

The implementation is `tools/bc2cpp/promote_candidates.rb`.
