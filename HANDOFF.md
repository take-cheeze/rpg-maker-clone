# Handoff: VM-free bc2cpp (as of 2026-11-09)

Paste this into a new session that has **take-cheeze/rpg-maker-clone** attached. Also attach
**take-cheeze/mruby** with push access (`add_repo`, `access: "push"`), because two of the
branches below need fork commits.

## Where things stand

- **rpg-maker-clone master:** `5821c5737` (#3196 merged). It contains:
  - the mruby fork bump, with `3rd/mruby` at fork `5ebf058c2` (152 upstream picks plus 8
    dynamic-call removals; by-name sends down about 86%);
  - the protected-call rule, where generated code passes the caller's `self`;
  - the frames-only link as the default: `mrb_vm_exec` is gone from the closed build, and
    `tools/bc2cpp/runtime/vm_frames.cxx` replaces vm-cxx.o.
- Everything from #3177 to #3196 is merged.
- **Upstream mruby merge:** deferred until the next upstream release (your call). Until then the
  fork gets cherry-picks only.

## Work in progress (pushed as snapshots; not reviewed, no PRs yet)

The background workers in the old session were still running when it ended. Each branch is
whatever they had committed at that point.

### 1. Remove the remaining by-name calls

- **rpg branch** `bc2cpp-byname-stage4`: 2 commits on master.
  - `8138bcb65` rgss: `read_font` runs the Font reader it finds instead of sending it by name.
  - `cc3d0ad85` bc2cpp: follows the fork's found-method calls for `==`, `eql?`, `<=>` and
    `Class#new`. It sets the `3rd/mruby` gitlink to fork `7e25a55`.
- **fork branch** `byname-stage4`: 2 commits on `5ebf058`.
  - `23b75df` `==`, `eql?` and `<=>` from C run the method they find, without a second lookup.
  - `7e25a55` `Class#new` and `mrb_obj_new` run the allocate and initialize they find.
- **Still to do:**
  - Re-measure the by-name send counts against master; the tools are in "Measuring" below.
  - Run the full check set, including the hardened build (`-fstack-protector-all`).
  - Then open a fork PR and a matching rpg PR.

### 2. Remove method tables: mruby gems to ROM tables

- **fork branch** `rom-gems`, on `5ebf058` (about 27 commits).
  - First, the visibility fix and its tests:
    - `3e1e94f` tests visibility changes on methods that come from ROM tables.
    - `48754a2` `remove_method` never deletes from a read-only top layer.
    - `f6c7275` `mrb_mt_init_rom` clears the method cache after bootstrap.
  - Then the core class files and the gems move to ROM tables (`MRB_MT_ENTRY` /
    `MRB_MT_INIT_ROM`), including singleton and module-function tables:
    - core: array, class, enum, error, gc, kernel, proc and string;
    - gems: math, io, time, pack, sprintf, numeric-ext, metaprog, exit, symbol-ext,
      string-ext and hash-ext.
  - Last: tests for ROM singleton tables (`d6513fd`), docs (`85e4fad`) and `60a989d`.
- **rpg side:** the verify worktree pointed `3rd/mruby` at this branch, but that wasn't
  committed. Bump the gitlink to the tip of `rom-gems`, then run the checks.
- **Still to do:**
  - Run the full check set on the rpg side.
  - Open a fork PR for `rom-gems`.
  - Open an rpg PR that bumps `3rd/mruby`.

### 3. Remove method tables: compiled code to ROM tables

- **rpg branch** `bc2cpp-rom-method-tables`: one commit, `6074da3ed`. It is behind master by 7
  and needs a rebase.
  - Each compiled class emits a `const mrb_mt_entry` table and installs it with
    `bc2cpp_mt_install`. Changed files: `codegen_emit.rb`, `codegen_resumable.rb`,
    `runtime/bc2cpp_fiber.hxx` and `bc2cpp.rb`.
  - New file `presym_spelling.rb`.
  - `BC2CPP_ROM_METHOD_TABLES=1` is set in `compiled_gems.rb`.
  - `trace_host.cxx` gains `BC2CPP_HOST_MT_HEAP`.
  - New check `scripts/bc2cpp/rom_method_tables_check.rb`, plus docs and changelog.
- **Depends on #2.** The visibility fix must be in the fork first.
- **To do:**
  - Rebase onto master after #2 lands. Mind the protected caller-`self` signature changes:
    `bc2cpp_proc_call_argv(M, self, recv, argc, argv)`, `symbol_cache.rb`.
  - Re-verify, then open the PR.

### Later items for removing method tables

- Move this repo's gems to ROM: mruby-rgss (84 entries), mruby-lcf, and the class-body
  `attr_*` (10 entries).
- Put an epoch-validated registration table behind `bc2cpp_find_method`. `mt_epoch` is already
  in `mrb_state`.

### Other open items

- About 178K extra method searches come from two owner-call sites. They aren't isolated yet.
- Follow-up: scope `status` in `native_ivar_scopes`.
- The readfloat long-literal pin bug waits for the full upstream merge.

## CI notes and lessons

- **`vm_free_inventory_check` ceilings:** `bc2cpp_owner_call` is at 2377. CI reads about 24
  higher than a local run, so leave headroom when lowering a ceiling. Update the table in
  `docs/bc2cpp-vm-free-runtime-plan.md` to match.
- **Checks to watch:**
  - `frames_only_check`, `vm_unreachable_check`, `base_section_check` (a new core class needs an
    RBS entry in `sig/bc2cpp/declarations.rbs`).
  - `audit_pins_check`: the digests in `NativeClassResults::FILES`.
  - `codegen_sort_array_cmp`'s digest of the whole of `array.c`. A mismatch there quietly drops
    an inline (+16.9M sends), so re-pin it when the fork's `array.c` changes.
- **Nix download flake:** `nix-quick-install-action` sometimes fails with zstd "unsupported
  format". That is an infra fault; re-run once.
- **When a helper's signature changes,** grep `scripts/` for hand-built hosts, shape regexes and
  every call site.
- **Run the hardened build too** (`-fstack-protector-all`), and test on the rebased tree.
- **Disk:** the per-session disk is small. Run one closed build at a time. Interrupted fixture
  checks leave `/tmp/bc2cpp_full*` directories of about 200MB each. Clear old ones with:
  `find /tmp -maxdepth 1 -name 'bc2cpp_full*' -type d -mmin +720 -exec rm -rf {} +`

## Measuring

- **By-name sends:** the closed build with the send wrapper counter.
- The old session's helpers lived in a scratchpad, which is gone: `wrapcnt.cxx`, `agg.rb` and the
  baseline `fork-bump-sends-plain.tsv`. Regenerate the baseline from master before comparing.
