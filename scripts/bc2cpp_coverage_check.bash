#!/usr/bin/env bash

set -euo pipefail

# Prove docs/bc2cpp_coverage.txt still matches what tools/bc2cpp/bc2cpp.rb's
# own whole-program diagnostic reports right now.
#
# scripts/bc2cpp_coverage_report.rb only regenerates the file when someone
# remembers to run it -- nothing enforced that a bc2cpp.rb call-site/codegen
# change, a compiled-gem source edit, or an mrblib change the whole-program
# registry sees actually got its stats-file update committed alongside it
# (confirmed missing: no CI step regenerated-and-diffed this file before this
# one, so a PR could freely drift the real coverage numbers with no visible
# signal). This regenerates the report against a real, already-built host
# mrbc and diffs the result against the committed file. Any drift at all is
# a hard failure with the regeneration command in the message.
#
# Needs a host mrbc already built -- the same prerequisite
# scripts/bc2cpp_coverage_report.rb's own header documents. Deliberately does
# NOT build one itself: the host mruby build's own gem set (mruby-rgss in
# particular) reaches real vendored headers (e.g. 3rd/stb's
# stb_image_write.h) only cmake/build-mruby.cmake's include paths resolve --
# hand-rolling a second, parallel `rake` invocation here would mean either
# duplicating that include-path setup (a maintenance/drift risk this repo's
# own tooling comments elsewhere explicitly avoid, e.g. compiled_gems.rb's
# "single source of truth" framing) or silently only exercising a narrower
# gem set than the real build's own host mrbc. The `build` job's own `cmake
# --build build` step already produces a real one as a side effect (every
# mruby build, cross or native, bootstraps a host mrbc first -- see root
# CMakeLists.txt's own "the native host build only produces mrbc" comment),
# so this runs right after it and points at that.
#
# Usage: scripts/bc2cpp_coverage_check.bash path/to/mruby/build/dir
#
# Takes the mruby build tree's own root (CMake's MRUBY_BUILD_DIR, e.g.
# build/mruby), not an exact mrbc path: mruby's own build system does not
# always place it at "$build_dir/host/bin/mrbc" -- a host build whose own
# compile flags a plain bootstrap compiler can't share (this project's own
# C++-exceptions-enabled host build included) gets its mrbc from a nested
# sub-build instead (confirmed for real against a CI run: "Config Name:
# host/mrbc", "Output Directory: ../../build/mruby/host/mrbc", i.e.
# "$build_dir/host/mrbc/bin/mrbc", not "$build_dir/host/bin/mrbc" -- that
# nesting is mruby/lib/mruby/build.rb's own `mrbcfile`/`build_mrbc_exec`
# internal bootstrap logic, not anything this project's build_config.rb
# controls, so hardcoding either exact path is a real drift risk this
# search sidesteps entirely).

cd "$(dirname "$0")/.."

build_dir="${1:-}"
if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
  echo "usage: $0 path/to/mruby/build/dir" >&2
  exit 1
fi

mrbc="$(find "$build_dir" -maxdepth 6 -type f -name mrbc -path '*/bin/mrbc' -perm -u+x -print -quit)"
if [ -z "$mrbc" ]; then
  echo "error: no executable bin/mrbc found under $build_dir" >&2
  exit 1
fi

report_file="docs/bc2cpp_coverage.txt"
expected="$(mktemp)"
trap 'rm -f "$expected"' EXIT

echo "regenerating $report_file against $mrbc ..."
MRBC="$mrbc" BC2CPP_COVERAGE_REPORT_PATH="$expected" ruby scripts/bc2cpp_coverage_report.rb >/dev/null

if diff -u "$report_file" "$expected"; then
  echo "ok: $report_file matches the real whole-program bc2cpp diagnostic"
  exit 0
fi

echo "::error::$report_file is stale -- it no longer matches what bc2cpp.rb's" \
  "own whole-program diagnostic reports." >&2
cat >&2 <<EOF

Regenerate it and commit the result alongside whatever change produced this
drift:

  MRBC=path/to/host/mrbc ruby scripts/bc2cpp_coverage_report.rb

EOF
exit 1
