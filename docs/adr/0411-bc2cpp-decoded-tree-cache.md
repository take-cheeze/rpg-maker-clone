# 0411. Share decoded bc2cpp trees within a CI job

Date: 2026-10-12

## Status

Accepted

## Context

Repeated whole-program generators run mrbc and decode its RITE output in
separate Ruby processes. A local full-source run spent about 0.24 seconds
in mrbc and 1.21 seconds decoding. The three engine compiled gems used
identical physical sources but spelled their roots as different `gem/..`
paths, so their debug filenames made the RITE images differ.

Analysis mutates the decoded objects and attaches memoized facts. Sharing live
objects or snapshots containing analysis state would leak proofs across runs.
A cache must contain only the initial decoded tree and restore private objects.

## Decision

Canonicalize source filenames in `closed_world_mrblib_srcs` without changing
source order. Provide `BC2CPP_IREP_CACHE_DIR` for job-local reuse and an
optional `decoded_tree_cache` input on manual nightly runs. It defaults off:
a three-process cold comparison regressed despite reducing repeated decoding.
Normal generation caches only
compilations whose sources belong to the tool's repository; temporary fixture
worlds bypass it because their unique debug filenames prevent reuse.

Key the decoded snapshot by exact RITE bytes, decoder-source contents, Ruby
engine/version/platform and Marshal format, and the EXT-prefix decoder mode.
The snapshot is written before any analysis. Each hit restores private mutable
trees and their tree cycles, and restores the decoder's frozen operand lists.

Use a per-key file lock on misses to let concurrent gems decode a shared world
once; warm readers restore outside the lock. Publish checksummed snapshots by atomic rename. A corrupt snapshot logs
its error and is rebuilt; compiler and decoder failures still propagate.
The cache is local to the job, with no restore across runners or runs.

## Consequences

On x86_64 Linux with CRuby 3.4.9/YJIT, full-source rpg2k generation took
13.25/13.29 seconds uncached, 14.12 seconds on the first cache fill, and
12.44 seconds on a hit. Emitted C++ matched byte for byte. The comparison
used the same canonical sources and default open-world proofs, without
outside-source overrides. Warm generation is about 6% faster; cache population
adds work, so the benefit depends on repeated worlds.

A three-process comparison generating all engine gem owners took 14.06 seconds
without the cache, 15.11 seconds on a cold cache and 12.96 seconds on a warm
cache. All emitted C++ matched, and one snapshot served all three processes.
Cold population therefore remains a regression for this parallel workload;
scheduled runs and the regular host build do not enable it automatically.

Normalizing the three engine gem roots produced identical RITE hashes in a
manual compilation check. Different bytecode, source filenames, decoder code
or EXT-prefix modes retain different keys. Unknown temporary worlds avoid the
serialization overhead. Analysis and generated-code caches remain separate.

`scripts/bc2cpp/decoded_cache_check.rb` covers private mutation, tree cycles,
read-only operand lists, input/mode/source-signature invalidation, visible
corruption recovery, propagated failures, source eligibility and concurrent
readers. The binary-loader and compiled-core tests cover real decoded input.
