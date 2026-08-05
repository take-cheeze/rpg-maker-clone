#!/usr/bin/env bash

# `git clone`, retried when it fails.
#
# Source this and call `clone_retry` with the arguments you would have given
# `git clone`.
#
# Several CI jobs fetch a test-bed game or an engine corescript from an external
# host, and those clones fail intermittently — not because anything is wrong
# with the repository or the checkout, but because the far end (or the runner's
# egress) hiccups for a moment. In the `wasm` job these fetches run as
# `background: true` steps, so a single failed clone takes the whole job down
# with it *before the compiler has run at all*, which reads like a build
# failure and is not one. Two different hosts have done it:
#
#   * github.com/aphadeon/OpenGame.exe   (scripts/download-opengame-xp.bash)
#   * github.com/rpgtkoolmv/corescript   (scripts/download-mv-corescript.bash)
#
# `wget` already retries on its own (20 attempts by default), so the archive
# downloads never needed this; `git clone` does not retry at all, which is why
# only the clones have been seen to fail.
#
# This is the same shape as scripts/nix-develop.bash, which retries the SQLite
# lock contention that job parallelism provokes: recover from a known transient
# failure at the point it happens rather than weakening the CI gate around it.
# Every caller clones into a directory it has just checked does not exist, so a
# repeat attempt costs nothing.

# The directory `git clone` would create for these arguments: the last
# non-option argument, or — when that is the URL, because no destination was
# given — the URL's last path segment without its `.git` suffix. Used to clear a
# partial clone before retrying.
clone_target() {
    local last='' arg
    for arg in "$@"; do
        case "$arg" in
        -*) ;;
        *) last="$arg" ;;
        esac
    done
    case "$last" in
    *://* | *@*:*)
        last="${last##*/}"
        printf '%s\n' "${last%.git}"
        ;;
    *) printf '%s\n' "$last" ;;
    esac
}

# Attempts and the initial backoff are read here rather than at source time, so
# a caller (or a test) can override them per invocation.
clone_retry() {
    local attempts=${GIT_CLONE_ATTEMPTS:-4}
    local delay=${GIT_CLONE_RETRY_DELAY:-5}
    local target attempt=1
    target="$(clone_target "$@")"
    while :; do
        if git clone "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$attempts" ]; then
            echo "git clone failed after $attempts attempts: $*" >&2
            return 1
        fi
        # A failed clone can leave a partial directory behind. Without clearing
        # it the next attempt dies with "already exists and is not an empty
        # directory" instead of actually retrying the fetch.
        if [ -n "$target" ] && [ -e "$target" ]; then
            rm -rf -- "$target"
        fi
        echo "git clone attempt $attempt/$attempts failed;" \
            "retrying in ${delay}s: $*" >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}
