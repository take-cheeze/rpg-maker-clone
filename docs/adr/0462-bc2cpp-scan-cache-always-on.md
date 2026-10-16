# 0462. bc2cpp: the scan cache is always on, and every cache fault is fatal

Date: 2026-10-16

## Status

Accepted

## Context

ADR 0415 added `ScanCache`, a content-addressed disk memo of the generator's outside-world scans: the mruby and gem C
sources (about 2.3 MB) that every closed-world run scans before it compiles anything. It was off unless
`BC2CPP_SCAN_CACHE_DIR` named a directory, and only the nightly workflow set that. So the PR gate's `bc2cpp-build`
job paid for the scans once for each compiled gem and again in the type check. So did a developer's build, and a
check script that never set the variable paid for them on every generator call.

A cache fault was reported to stderr and then recomputed past: an unreadable entry, a value that could not be dumped,
a directory that could not be written. That keeps the run going, but it also hides a writer bug or a format mix-up.

## Decision

* **Always on, no environment switch.** Entries live in the checkout's git-ignored `build/bc2cpp-cache`
  (`ScanCache::DEFAULT_DIR`, relative to `tools/bc2cpp`). `BC2CPP_SCAN_CACHE_DIR` is gone. A check that needs its own
  directory sets `ScanCache.directory_override` from Ruby; `ScanCache.bypass { }` computes every scan and touches no
  file, which is how a check gets the uncached reference.
* **The key** is ADR 0415's (scan name, digest of every `tools/bc2cpp/*.rb`, each input path and the digest of its
  bytes or its absence) plus the Ruby version, platform and Marshal format version. Entries now carry a header and
  the key they were stored under.
* **The environment cannot change a result.** The key holds no environment, so a cached scan may not read any. This
  is now enforced rather than reviewed: while a cached scan computes, any `ENV` read raises `ScanCache::Error`.
* **Every fault is fatal.** These raise `ScanCache::Error` and are never recomputed past: an entry that does not
  load, an entry whose stored key is not the key it was read under (or that has no header), a value that cannot be
  dumped, and a directory that cannot be written. A plain miss computes and stores.

## Consequences

* Every generator run after the first in a checkout loads the scans. ADR 0415 measured a warm one-method fixture call
  at 2.7 s against 3.55 s without the cache, and `numeric_slow` at 316 s against 398 s. The PR gate's build now gets
  that warm path for every compiled gem after the first. The benchmark of record for this change is the PR's CI
  `bc2cpp-build` duration against master's.
* The nightly workflow's `BC2CPP_SCAN_CACHE_DIR` lines no longer do anything. The cache now lives in each job's
  checkout, which is fresh per job, so it is still never shared between jobs.
* A tool copied outside a checkout (a mutation check's copy of `tools/bc2cpp`) keeps its cache two levels up from
  the copy. Its entries cannot be read by the original tool, because the tool digest is in the key.
* A stale entry cannot be read: the content digests and the tool digest are in the key. A damaged one stops the run,
  naming the file, so it is found rather than silently replaced.
* `scripts/bc2cpp/scan_cache_check.rb` covers the bypass, hit, miss on an input change, miss on a tool change, the
  fatal faults, the ENV guard, concurrent writers, and the real scanners cached against uncached.
