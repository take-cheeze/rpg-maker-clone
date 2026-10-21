# Trace candidate merge

`scripts/bc2cpp/trace_types.rb candidates` writes RBS candidates from `BC2CPP_TRACE_TYPES` dumps. They are for review
and are not loaded. `scripts/bc2cpp/trace_merge.rb` compares them with `sig/bc2cpp/declarations.rbs`:

```sh
ruby scripts/bc2cpp/trace_merge.rb CANDIDATES.rbs
```

It writes the candidates the file does not already declare to `generated/bc2cpp/trace_proposals.rbs`, and reports:

- **already declared** with the same signature: skipped;
- **conflicting**: a method declared with a different signature. The declaration is kept and the candidate is
  listed for review;
- **interfaces**: counted, not read.

The proposals file is outside `sig/` on purpose. `rbs_signatures.rb` loads every `sig/**/*.rbs`, so a file there would
become program hints. Moving a proposal into `sig/bc2cpp/declarations.rbs` is a reviewed edit. Nothing in the tool
writes that file.

`scripts/bc2cpp/trace_merge_check.rb` is the host-only check (fixture candidates, a parse-back of the proposals, and the
committed declarations proposing nothing against themselves). It runs in the bc2cpp CI list.
