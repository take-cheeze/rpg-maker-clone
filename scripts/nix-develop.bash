#!/usr/bin/env bash

set -euo pipefail

# `nix develop -c "$@"`, retried when the Nix store database is locked.
#
# CI installs Nix single-user (nixbuild/nix-quick-install-action), so there is
# no nix-daemon serialising store access: every `nix` process opens
# /nix/var/nix/db/db.sqlite itself and takes the SQLite write lock directly.
# Each job now calls this exactly once, as a warm-up that realises the dev
# shell before `nicknovitski/nix-develop` exports its environment into
# $GITHUB_ENV / $GITHUB_PATH for every later step (see the `build` job) — so
# there is no longer a second `nix` process around to race for that lock. The
# retry stays as cheap insurance against a stray concurrent `nix` invocation
# still hitting
#
#     error: SQLite database '/nix/var/nix/db/db.sqlite' is busy
#
# SQLite returns SQLITE_BUSY immediately rather than waiting out the busy
# timeout when a reader has to upgrade to a writer, and nix turns that straight
# into a fatal error, so the step fails even though nothing is actually wrong.
# Retry here instead, backing off to give the winner time to finish. Only that
# error is retried; any other failure exits with the command's own status.
# Every caller runs an idempotent command, so a repeat attempt costs nothing.
#
# The evaluation cache reports the same contention as
# `error (ignored): SQLite database '.../eval-cache-v6/<hash>.sqlite' is busy`.
# That one only loses a cache entry and nix carries on, so the pattern below
# anchors at `^error:` to leave it alone.

attempts=${NIX_DEVELOP_ATTEMPTS:-4}
delay=${NIX_DEVELOP_RETRY_DELAY:-5}

# `nix develop` fetches this flake with `self.submodules = true`, which makes
# nix fetch every submodule from its remote with the refspec `refs/*:refs/*`
# and `--progress`: a `* [new ref]` line per ref — ~20k of them, GitHub's
# `refs/pull/*` included, on the first nix command of a job — plus the object
# counters git would otherwise keep to itself when stderr is not a terminal. It
# all comes from a `git` child process holding nix's stderr, so no nix
# verbosity flag suppresses it; see the filter for the full story. The same
# filter also quiets the clones the download scripts run inside the shell.
drop_fetch_noise="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drop-git-fetch-noise.bash"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for ((attempt = 1; ; attempt++)); do
    set +e
    # `tee` is what lets the retry check read nix's diagnostics while they
    # still stream live, hence PIPESTATUS for the real exit status — which is
    # still element 0 with the filter spliced in ahead of `tee`.
    nix develop -c "$@" 2>&1 | "$drop_fetch_noise" | tee "$log"
    status=${PIPESTATUS[0]}
    set -e

    if [ "$status" -eq 0 ]; then
        exit 0
    fi

    if [ "$attempt" -ge "$attempts" ] ||
        ! grep -qE "^error: SQLite database '.*' is busy" "$log"; then
        exit "$status"
    fi

    echo "nix-develop.bash: Nix store is locked by a concurrent nix process," \
        "retrying in ${delay}s (attempt $((attempt + 1))/${attempts})" >&2
    sleep "$delay"
    delay=$((delay * 2))
done
