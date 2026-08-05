#!/usr/bin/env bash

set -euo pipefail

# Start a nix-daemon for this job and point every later nix command at it.
#
# CI installs Nix single-user (nixbuild/nix-quick-install-action), so nothing
# serialises store access: every `nix` process opens /nix/var/nix/db/db.sqlite
# itself and takes the SQLite write lock directly. The `build` and `wasm` jobs
# deliberately fan out into concurrent `nix develop` steps, so they contend for
# that lock and the loser dies with
#
#     error: SQLite database '/nix/var/nix/db/db.sqlite' is busy
#
# scripts/nix-develop.bash recovers from that after the fact by retrying. A
# daemon removes it at the source instead: every store operation is funnelled
# through one process that serialises database access internally.
#
# The daemon started here runs as the runner user — the same user that already
# owns /nix — so this buys serialisation only, not the privilege separation a
# real multi-user install has. That is fine; serialisation is the entire point.
#
# Deliberately *not* a `background: true` step. Those are joined by the `wait:`
# barriers and are expected to terminate, and a daemon never does. Backgrounding
# it inside an ordinary step leaves it as an orphan that the runner reaps at job
# end — the job logs already show it doing exactly that for sccache.

socket="${NIX_STATE_DIR:-/nix/var/nix}/daemon-socket/socket"
log="${RUNNER_TEMP:-/tmp}/nix-daemon.log"

# `trusted-users` is read by the daemon at startup, so it has to be in place
# before the daemon is launched. An untrusted client cannot select its own
# substituters; the daemon's own configuration still applies, so the default
# cache.nixos.org keeps working either way and this repository's flake carries
# no `nixConfig` block that would need honouring. Appended rather than passed
# through the action's `nix_conf` input because that input is documented to
# write this very file, and whether it replaces or merges the defaults the
# action itself sets (experimental-features, accept-flake-config) is not
# specified — appending cannot clobber them.
conf="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$conf")"
if ! grep -q '^trusted-users' "$conf" 2>/dev/null; then
    echo "trusted-users = root $(id -un)" >>"$conf"
fi

if [ -S "$socket" ]; then
    echo "nix-daemon is already listening at $socket"
else
    mkdir -p "$(dirname "$socket")"

    # `nix-daemon` is the stable spelling; `nix daemon` is the new-CLI one and
    # needs the nix-command experimental feature. Prefer the former.
    if command -v nix-daemon >/dev/null 2>&1; then
        daemon=(nix-daemon)
    else
        daemon=(nix daemon)
    fi

    # Output goes to a file, never to the step's stdout: a backgrounded child
    # holding that pipe open can keep the step from ever completing.
    nohup "${daemon[@]}" >"$log" 2>&1 &

    for _ in $(seq 100); do
        [ -S "$socket" ] && break
        sleep 0.2
    done
fi

if [ ! -S "$socket" ]; then
    echo "nix-daemon did not create $socket within 20s. Daemon log:" >&2
    cat "$log" >&2 || true
    exit 1
fi

# Every later step in this job talks to the daemon rather than the store.
echo "NIX_REMOTE=daemon" >>"${GITHUB_ENV:-/dev/null}"
export NIX_REMOTE=daemon

# Proof that the client actually reached the daemon rather than silently
# falling back to the local store: this prints `Store URL: daemon`. Kept
# non-fatal so an older nix without `nix store info` cannot fail the step.
nix store info || nix store ping || true
