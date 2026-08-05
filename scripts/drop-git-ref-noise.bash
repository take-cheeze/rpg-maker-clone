#!/usr/bin/env bash

set -uo pipefail

# Stream filter that drops the per-ref table `git fetch` prints. Reads stdin,
# writes what survives to stdout; put it at the end of a pipe.
#
#     nix build -L '.#build' 2>&1 | ./scripts/drop-git-ref-noise.bash
#
# flake.nix sets `self.submodules = true`, so every `nix develop` / `nix build`
# hands each of this repo's submodules to nix's own git fetcher. Nix builds
# that fetcher input (src/libfetchers/git.cc) from the URL in `.gitmodules`
# with `allRefs = true` hardcoded, and `allRefs` picks the refspec
# `refs/*:refs/*` — literally every ref the remote has, including the
# `refs/pull/*` heads GitHub keeps for each pull request ever opened and that a
# normal clone never fetches. mruby and lvgl have thousands each, so the first
# nix command of a job prints ~20k lines of
#
#     * [new ref]   refs/pull/4258/head  -> refs/pull/4258/head
#
# before the build has started, burying the rest of the job log. It happens
# once per job: the fetch is skipped when the submodule's revision is already
# in nix's `~/.cache/nix/gitv3` (`doFetch = !repo->hasObject(*rev)`), which the
# first command populates.
#
# Nix's own verbosity flags cannot reach it. `nix ... --quiet` lowers the level
# of nix's logger, but this fetch is the real `git` binary run with
# `--progress`, no `--quiet`, and `isInteractive = true`
# (src/libfetchers/git-utils.cc), which hands git nix's stderr directly instead
# of routing it through that logger. Filtering the stream is what is left.
#
# Only the ref-table lines go. `From <url>`, `remote:` counters and everything
# git prints when a fetch actually fails stay, so a broken fetch still reads
# exactly the way it did before. Requiring a full `refs/...` name keeps the
# ordinary summaries of the plain clones this repo also runs
# (scripts/download-*.bash, via git-clone-retry.bash) — `* [new branch]
# master -> origin/master` and friends, a handful of lines — where they are.

grep --line-buffered -v -E '^ [*+] \[new (ref|tag|branch)\][[:space:]]+refs/'
status=$?

# grep exits 1 when it selected no lines. For a filter that only means the
# input was empty (or was all noise) — not a failure, and the callers run under
# `pipefail`, where returning 1 would fail the step. Any other status is a real
# grep error and is passed on.
[ "$status" -eq 1 ] && exit 0
exit "$status"
