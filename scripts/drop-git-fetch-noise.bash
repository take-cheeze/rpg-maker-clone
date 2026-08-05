#!/usr/bin/env bash

set -uo pipefail

# Stream filter that drops the bookkeeping `git fetch` and `git clone` print
# while they transfer. Reads stdin, writes what survives to stdout; put it at
# the end of a pipe.
#
#     nix build -L '.#build' 2>&1 | ./scripts/drop-git-fetch-noise.bash
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
# of routing it through that logger. That forced `--progress` is also why the
# object counters below reach a CI log at all — git suppresses those on its own
# when stderr is not a terminal. Filtering the stream is what is left.
#
# The same filter covers the plain clones this repo runs inside the dev shell
# (scripts/download-*.bash, via git-clone-retry.bash), which print the same
# counters.
#
# What deliberately stays:
#
#   * `From <url>` — one line per repository, the breadcrumb that says which
#     fetches happened at all.
#   * `remote:` lines other than the object counters, so a server-side message
#     like `remote: Repository not found.` is still readable.
#   * `! [rejected]` rows, and anything on the `fatal:` / `error:` paths: a
#     fetch that fails reads exactly the way it did before this filter existed.

patterns=(
    # The per-ref table of a `refs/*:refs/*` fetch. Anchoring on a full
    # `refs/...` name is what keeps the ordinary summary of a plain clone
    # (`* [new branch] master -> origin/master`, a handful of lines) visible.
    '^ [*+] \[new (ref|tag|branch)\][[:space:]]+refs/'
    '^ = \[up to date\][[:space:]]+refs/'
    '^ - \[deleted\][[:space:]]+\(none\)[[:space:]]+-> +refs/'
    # Ref rows for a cache that already had the repository: fast-forward
    # (`   aaaaaaa..bbbbbbb  refs/…`) and forced (`+ aaaaaaa...bbbbbbb refs/…`).
    '^ {3}[0-9a-f]+\.\.[0-9a-f]+[[:space:]]+refs/'
    '^ \+ [0-9a-f]+\.\.\.[0-9a-f]+[[:space:]]+refs/'
    # Transfer progress. Each is a `\r`-driven counter that only reaches a log
    # file because nix forces `--progress`.
    '^(Enumerating|Counting|Compressing|Receiving|Unpacking|Indexing) objects:'
    '^Resolving deltas:'
    '^(Updating|Checking out) files:'
    '^Filtering content:'
    # The remote's half of the same counters. Spelled out one by one rather
    # than dropping every `remote:` line, so real server messages survive.
    '^remote: (Enumerating|Counting|Compressing|Finding sources|Total) '
    # Clone and submodule bookkeeping.
    "^Cloning into (bare repository )?'"
    "^Submodule '.*' \(.*\) registered for path '"
    "^Submodule path '.*': checked out '"
)

args=()
for pattern in "${patterns[@]}"; do
    args+=(-e "$pattern")
done

grep --line-buffered -v -E "${args[@]}"
status=$?

# grep exits 1 when it selected no lines. For a filter that only means the
# input was empty (or was all noise) — not a failure, and the callers run under
# `pipefail`, where returning 1 would fail the step. Any other status is a real
# grep error and is passed on.
[ "$status" -eq 1 ] && exit 0
exit "$status"
