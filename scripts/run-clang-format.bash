#!/usr/bin/env bash

set -eux -o pipefail

cd $(git rev-parse --show-toplevel)

git ls-files '*.cc' '*.cxx' | xargs -P$(nproc) clang-format -i

git diff --exit-code
