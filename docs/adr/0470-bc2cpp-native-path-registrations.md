# 0470. bc2cpp: scan each native source's registrations once per run, not once per asked name

Date: 2026-10-16

## Status

Accepted

## Context

A StackProf profile (CPU mode, 2 ms) of the wio closed-world shipped pass on master 3d348c10, after ADR 0467 and its
follow-up, took 30,840 samples. GC was 15.9% of them, and `NumericFlow.states` (inclusive, with its oracle) 33.8%.
The flow's own methods were 13.7% of the pass, led by `join_state` at 5.3%.

The largest single item that is the same work done again is `CodeGen#nil_unanswerable_refusal`, at 7.5% inclusive
(2,315 samples). Most of it runs under the flow's oracle, through `core_ruby_class_result`. It is memoized per name.
For each name it loops over `ClosedWorld#native_paths_spelling(name)` and calls
`NativeExpressionDevirt.scan_class_registrations([path])` on each source. That scan runs the class-variable,
`MRB_MT_INIT_ROM`, ROM-table and `mrb_define_*` scans of the whole file, splitting the arguments of every call it
finds. Many names share a source, so the same files were scanned again for every name. That accounted for 1,533
samples (5.0% of the pass), and with it most of the pass's `String#[]` (4.6% self, nearly all in
`split_call_arguments`) and 60% of its `String#scan`. This is the same shape ADR 0461 fixed for
`outside_ruby_paths_defining`, where a file was rescanned for every asked name.

## Decision

`NATIVE_PATH_REGISTRATIONS`: `NativeExpressionDevirt.path_registrations(path)` returns
`scan_class_registrations([path])` and keeps the result for the run. `nil_unanswerable_refusal` reads the native
registrations through it.

* The key is complete. The scan reads only the path and the file's text: `read_source`, the class-variable map of that
  text, and pure helpers (`symbol_name`, `safe_arity`, `unescape_c_string`). The memo stores the `read_source` String
  next to the answer and reuses the answer only while `read_source(path)` returns that same object. `read_source` is
  keyed by path, mtime and size, so a rewritten source gets a new String and is scanned again.
* The two maps and their entry lists are frozen. The caller only `fetch`es from them, and the scan's default procs
  never fire on `fetch`.
* A path that is not a file answers the scan's empty maps and is not cached.
* `class_registrations` (a multi-path union with the on-disk scan cache) and `frozen_table_outside_registrations` are
  unchanged.

## Consequences

* The generated C++ of the wio shipped pass is byte-identical to master's (`cmp`, 431,313 lines). The stderr differs
  only in its timing lines.
* Under the same profiler, `nil_unanswerable_refusal` falls from 2,315 to 686 samples and `scan_class_registrations`
  from 1,805 to 310. That saves about 3.3 s of CPU per pass, and every build of the analysis pays it once.
  The whole pass went from 30,840 to 26,111 samples, 121.6 to 103.0 s user and 2:08 to 1:47.5 wall. The 4-CPU host
  was shared (load 4–5 during the first run and 2.5–3.5 during the second), so most of the remaining difference is
  noise. CI's bc2cpp-build job time is the end-to-end figure. Max RSS is unchanged (858 MB and 868 MB).
* On all 177 native sources of the engine's tree (59 with registrations), `path_registrations` equals a fresh
  `scan_class_registrations([path])`, key by key. A second ask returns the same frozen object.
* `scripts/bc2cpp/native_path_registrations_check.rb` (host only, about 0.1 s) checks that the answer equals a fresh
  scan, that a second ask does not scan, that the maps are frozen, that a rewritten source is scanned again, that a
  missing path is not cached, and that `nil_unanswerable_refusal` uses the memo.
* Left for later, measured in the same profile: `ForeignDefiners.scan` rebuilds and hashes its stat key of every
  foreign Ruby path on each `defines?` call. That is 876 samples (2.8%) under `nil_foreign_definition_free?`.
  `NumericFlow.join_state` is still the flow's largest own cost.
