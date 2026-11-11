#!/usr/bin/env bash

set -eu -o pipefail

# Deregister 3rd/nfcxx's own submodules (the EDG front end, QBE, cproc and its mruby gems) from the local checkout.
# This repository uses nfcxx only for bc2cpp (its bc2cpp/ tree); those submodules belong to nfcxx's C++ compiler.
#
# A recursive checkout already leaves them out (scripts/checkout-submodules.bash marks them `update = none`). Nix does
# not: `nix build '.?submodules=1#build'` (the `flake` CI job) walks every nested `.gitmodules` entry and fails on a
# missing directory. As scripts/skip-quickjs-test262.bash does for quickjs's test262, the `.gitmodules` sections and
# the gitlinks are dropped instead. That only dirties the nfcxx checkout, and nothing in this build reads them.
#
# Idempotent, so jobs can run it after any checkout.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nfcxx="${repo_root}/3rd/nfcxx"

if [ ! -e "${nfcxx}/.git" ]; then
  echo "3rd/nfcxx is not checked out; nothing to do"
  exit 0
fi

for name in $(git -C "${nfcxx}" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $1}' |
              sed -e 's/^submodule\.//' -e 's/\.path$//'); do
  path=$(git -C "${nfcxx}" config --file .gitmodules "submodule.${name}.path")
  # bc2cpp/3rd/prism and bc2cpp/3rd/rbs are the RBS and Prism forks the bc2cpp runner builds from, so they stay.
  case "${path}" in bc2cpp/3rd/*) continue ;; esac
  git -C "${nfcxx}" config --file .gitmodules --remove-section "submodule.${name}"
  if git -C "${nfcxx}" ls-files --error-unmatch "${path}" >/dev/null 2>&1; then
    git -C "${nfcxx}" update-index --force-remove "${path}"
  fi
  echo "dropped 3rd/nfcxx's ${path} submodule"
done
