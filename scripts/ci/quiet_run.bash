#!/usr/bin/env bash
# Runs one command with its output in a log (docs/ci.md, "Quiet output"). On success it prints a one-line
# summary and the `::error`/`::warning`/`::notice` workflow lines the command wrote; on failure it prints the
# whole log in a collapsed group, then its last lines and the status, and exits with the command's status.
# CI_VERBOSE=1 prints the whole log on success too.
#
#   scripts/ci/quiet_run.bash COMMAND [ARG]...
set -uo pipefail

[ "$#" -gt 0 ] || {
  echo "usage: quiet_run.bash COMMAND [ARG]..." >&2
  exit 2
}
TAIL_LINES="${QUIET_RUN_TAIL:-200}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
start="$(date +%s)"
"$@" >"$log" 2>&1
status=$?
secs=$(($(date +%s) - start))
lines="$(wc -l <"$log")"
warnings="$(grep -c ': warning:' "$log")"
label="$*"

grep -E '^::(error|warning|notice)( |::)' "$log"
if [ "$status" = 0 ]; then
  [ "${CI_VERBOSE:-0}" = 1 ] && cat "$log"
  printf 'ok (%ss, %s line(s) of output, %s compiler warning(s)): %s\n' "$secs" "$lines" "$warnings" "$label"
  exit 0
fi
printf '::group::full output of %s\n' "$label"
cat "$log"
printf '::endgroup::\n'
printf '== FAILED (exit %s, %ss): %s -- last %s line(s):\n' "$status" "$secs" "$label" "$TAIL_LINES"
tail -n "$TAIL_LINES" "$log"
exit "$status"
