#!/usr/bin/env bash

set -euo pipefail

# Realise the flake's dev shell and export its resolved environment into
# $GITHUB_ENV / $GITHUB_PATH, so every later step in the job already runs
# inside it -- no need to route each step's command through
# `./scripts/nix-develop.bash` (`nix develop -c ...`). A same-repo
# reimplementation of the `nicknovitski/nix-develop` GitHub Action
# (https://github.com/nicknovitski/nix-develop/blob/v1/nix-develop-gha.sh),
# to avoid taking on a third-party Action for this one step; the technique
# below is theirs.
#
# `nix develop -c bash -c 'echo -ne "\0"; env -0'` runs the shell for real
# and dumps its fully realised environment (including anything the
# shellHook set), NUL-delimited. The leading `echo -ne '\0'` fences off
# whatever the shellHook printed to stdout from the `env -0` dump that
# follows it, so the read loop below can discard that first record instead
# of trying to parse it as NAME=VALUE. Comparing every later entry against
# the *current* process's environment is what keeps $GITHUB_ENV to just the
# shell's actual additions/changes rather than every inherited variable.
#
# PATH is handled separately: GitHub Actions *prepends* each line written
# to $GITHUB_PATH to $PATH for later steps, so appending the shell's PATH
# entries in forward order would leave them in reverse order. Writing them
# in reverse undoes that. Entries already on $PATH, or that do not exist as
# directories (nix can list one for a build input the shell does not
# actually need), are skipped.
#
# This is the first `nix` command of the job, so its stderr is piped through
# the same noise filter `./scripts/nix-develop.bash` uses: fetching this
# flake with `self.submodules = true` makes nix fetch every submodule with
# `refs/*:refs/*`, a `* [new ref]` line per ref -- see the filter for the
# full story.

contains() {
    # -F: nix store paths and the base64 delimiter below can contain regex
    # metacharacters (`.`, `+`); this only ever needs a literal substring
    # match.
    grep -F --silent -- "$1" <<<"$2"
}

drop_fetch_noise="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drop-git-fetch-noise.bash"

env_output=

# On the last iteration `read` hits EOF without a NUL delimiter (the
# trailing exit-status digits below have no delimiter after them), so it
# fails and leaves that status string in $name -- `|| exit "$name"` is what
# turns that into this script's own exit status, propagating whatever `nix
# develop` and the command it ran actually exited with.
while IFS='=' read -r -d '' name value || exit "$name"; do
    if [ -z "$env_output" ]; then
        env_output=1
        continue
    fi

    if [ "$name" = PATH ]; then
        IFS=':' read -r -a nix_path <<<"$value"
        for ((i = ${#nix_path[@]} - 1; i >= 0; i--)); do
            entry="${nix_path[$i]}"
            contains "$entry" "$PATH" && continue
            [ -d "$entry" ] || continue
            echo "$entry" >>"$GITHUB_PATH"
        done
        continue
    fi

    [ "${!name:-}" = "$value" ] && continue

    if (($(wc -l <<<"$value") > 1)); then
        # Ref: workflow-commands-for-github-actions#setting-an-environment-variable
        # GitHub's parser requires the closing delimiter on its own line, so
        # $value needs a trailing newline before it -- and env -0 does not
        # give every multi-line value one (an exported bash function, which
        # `nix develop`'s setup hooks leave several of, ends right after its
        # closing `}`). Add one only when it is missing, or a value that
        # already ended in a newline would gain a spurious blank line.
        delimiter=$(openssl rand -base64 18)
        if contains "$delimiter" "$value"; then
            echo "nix-develop-export-env.bash: '$name' contains the" \
                "generated delimiter $delimiter; buy a lottery ticket and" \
                "retry." >&2
            exit 1
        fi
        printf '%s<<%s\n%s' "$name" "$delimiter" "$value" >>"$GITHUB_ENV"
        [[ "$value" == *$'\n' ]] || printf '\n' >>"$GITHUB_ENV"
        printf '%s\n' "$delimiter" >>"$GITHUB_ENV"
        continue
    fi

    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_ENV"
done < <(
    set +e
    nix develop -c bash -c "echo -ne '\0'; env -0" 2> >("$drop_fetch_noise" >&2)
    printf '%s' "$?"
)
