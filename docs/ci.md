# Continuous integration

[`.github/workflows/build.yml`](../.github/workflows/build.yml) is the one CI
workflow. It runs on pull requests to `master`, pushes to `master`, merge-queue
runs, manual dispatch and (for the Cloudflare preview only) `/preview` comments.
Deployment is covered in [deploy.md](deploy.md).

## bc2cpp gate

The status check `bc2cpp` is the aggregate of `bc2cpp-build`, every
`bc2cpp-checks (<shard>)` and every `bc2cpp-width (<variant>)` job. Require
`bc2cpp` rather than the individual shards, so adding a shard needs no settings
change.

### Width builds (ADR 0300)

The Emscripten, Wio and PSP targets use a 32-bit `mrb_int`; Wio and PSP also
have no mruby-bigint. `bc2cpp-width` re-runs the compiled-versus-interpreted
checks on a libmruby built by `scripts/bc2cpp_width_build.rb`:

| Variant | Build | Checks |
| --- | --- | --- |
| `int32` | full-core, `-DMRB_32BIT -DMRB_INT32` (31-bit Fixnums) | `numeric_slow`, `fixnum_overflow`, `step_inline`, `unlisted_class_call`, `lcf_row_flow` |
| `nobigint` | full-core without mruby-bigint / mruby-rational | `numeric_slow` |

The 32-bit build is the 64-bit host with the targets' arithmetic defines, so it
does not exercise 32-bit pointers. To run a variant locally, after the mruby
patch chain has been applied (any cmake build does it):

```bash
ruby scripts/bc2cpp_width_build.rb int32 /tmp/w32
BC2CPP_MRUBY_FULL32=/tmp/w32/host BC2CPP_MRBC32=/tmp/w32/host/bin/mrbc \
  MRBC=<64-bit host mrbc> ruby scripts/bc2cpp_numeric_slow_check.rb
```

A check whose environment variable is missing prints `SKIP` and exits 0; the
job fails instead when the libmruby it should have built is absent.

## Cross-PR interaction (merge queue)

A pull request is tested against the `master` it branched from. Two PRs that
are each green can still break `master` together. The workflow listens for
`merge_group` events so it can be a merge queue's gate, but **the repository
owner has to turn the protection on** (Settings, not code):

1. **Preferred: a merge queue.** Settings, Rules, Rulesets (or Branches, branch
   protection rule for `master`): enable **Require merge queue**. Keep the
   required status checks (at least `bc2cpp`, plus the other required jobs) and
   set a build concurrency of 1 to 3. The queue then runs this workflow on each
   PR merged onto the current `master` and the PRs ahead of it, and merges only
   on success. Auto-merge keeps working: it enqueues the PR.
2. **Cheaper alternative.** Enable **Require branches to be up to date before
   merging** on the same protection rule. A PR must then contain the latest
   `master` before it merges, so CI has seen the combination, at the cost of
   re-running CI after every other merge.

Notes for the queue run: `deploy-pages` still needs a `push` to `master`, and
`preview-cloudflare` only an `issue_comment`, so neither fires on `merge_group`.
The `changes` job's path filter (dorny/paths-filter) has not been exercised on a
`merge_group` run; watch the first queued PR for it. A required check must be reported on
`merge_group` as well as on `pull_request`; every job here has no event filter
beyond excluding `issue_comment`, so it is.
