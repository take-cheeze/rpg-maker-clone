#!/usr/bin/env bash

set -eu -o pipefail

# Deregister quickjs-ng's nested `test262` submodule from the local checkout so
# nothing ever clones https://github.com/tc39/test262 — the tc39 conformance
# suite, tens of thousands of files that nothing in this build uses.
#
# git already skips it: quickjs-ng pins the entry with `update = none`, so a
# recursive checkout leaves the directory absent. Nix does not — a call that
# fetches this flake with submodules walks every entry of every nested
# `.gitmodules`, including this one, which fails on the missing directory. The
# previous fix cloned test262 (shallow) purely to satisfy that walk; dropping
# the entry instead keeps the walk happy for free.
#
# Only `nix build '.?submodules=1#build'` (the `flake` CI job) asks for that
# walk now — flake.nix no longer declares `self.submodules = true`, so
# `nix develop` skips it, and the dev-shell jobs no longer run this at all.
# Still worth running by hand before any `?submodules=1` command on a checkout
# that has the entry registered.
#
# Both the `.gitmodules` section and the gitlink go: an index entry with no
# `.gitmodules` mapping is an orphan that `git submodule status` itself errors
# on. This only dirties the quickjs checkout — nix copies the working tree as
# is, no file on disk is removed, and nothing in the build reads either.
#
# Idempotent, so jobs can run it after any checkout. Set CLONE_TEST262=1 to opt
# out and keep the submodule registered (then materialise it with
# `git -C 3rd/quickjs -c submodule.test262.update=checkout \
#      submodule update --init --depth 1 test262`).

if [ "${CLONE_TEST262:-}" = "1" ]; then
  echo "CLONE_TEST262=1: leaving quickjs's test262 submodule registered"
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
quickjs="${repo_root}/3rd/quickjs"

if [ ! -e "${quickjs}/.git" ]; then
  echo "3rd/quickjs is not checked out; nothing to do"
  exit 0
fi

if git -C "${quickjs}" config --file .gitmodules --get-regexp '^submodule\.test262\.' \
  >/dev/null 2>&1; then
  git -C "${quickjs}" config --file .gitmodules --remove-section submodule.test262
  echo "dropped submodule.test262 from 3rd/quickjs/.gitmodules"
fi

if git -C "${quickjs}" ls-files --error-unmatch test262 >/dev/null 2>&1; then
  git -C "${quickjs}" update-index --force-remove test262
  echo "dropped the test262 gitlink from 3rd/quickjs's index"
fi
