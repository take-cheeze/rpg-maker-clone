#!/usr/bin/env bash

set -eux -o pipefail

cd $(git rev-parse --show-toplevel)

git ls-files '*.cmake' 'CMakeLists.txt' | xargs -P$(nproc) cmake-format -i

git diff --exit-code
