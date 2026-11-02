#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns a workflow `checks:` block (one shell command per line, read from stdin) into a bash script
# that runs the same commands, in the same shell and order, and ends with a "seconds  command"
# table sorted slowest first (docs/ci.md, "Timing table").
#
#   ruby scripts/ci/timed_checks.rb > "$RUNNER_TEMP/checks.sh" <<'CHECKS'
#   ...the checks block...
#   CHECKS
#   source "$RUNNER_TEMP/checks.sh"
#
# The commands are not rewritten, only bracketed by __ci_begin/__ci_end, so a failing one still
# aborts the step under `set -e` with its own status. An EXIT trap prints the table on success and on
# failure alike (the command that failed is listed as FAILED with the time it ran).
#
# Full output is printed by default, grouped per parallel command. CI_VERBOSE=0 is an explicit
# local opt-in to annotation-only successful logs; failures always retain their full output.
#
# Commands between `# ci:parallel begin [N]` and `# ci:parallel end` run at the same time, at most N at a time
# (docs/ci.md, "Parallel groups"); everything else runs in order as before.
#
# Comment lines and blank lines are dropped; a `\` continuation is joined. Lines that only set shell
# variables (`width=...`, `export A=b`) are passed through untimed, since later commands rely on them.
require 'shellwords'

PRELUDE = <<~'BASH'
  __ci_rows="$(mktemp)"
  __ci_label=
  __ci_start=
  __ci_verbose="${CI_VERBOSE:-1}"
  # A serial command writes to fd 4: its own log, or the step's stdout (saved as fd 3) under CI_VERBOSE=1.
  # A duplicated descriptor, not /dev/fd/3, which reopens (and truncates) a stdout redirected to a file.
  exec 3>&1
  __ci_log="$(mktemp)"
  __ci_now() { date +%s.%N; }
  # The workflow commands (annotations) of a passing command's log: the only part of it that is printed.
  __ci_annotations() { grep -E '^::(error|warning|notice)( |::)' "$1" || true; }
  __ci_begin() {
    __ci_label="$1"
    __ci_start="$(__ci_now)"
    if [ "$__ci_verbose" = 1 ]; then exec 4>&3; else exec 4>"$__ci_log"; fi
  }
  __ci_end() {
    local secs
    secs="$(awk -v a="$__ci_start" -v b="$(__ci_now)" 'BEGIN { printf "%.1f", b - a }')"
    printf '%s\t%s\t%s\n' "$secs" ok "$__ci_label" >> "$__ci_rows"
    __ci_annotations "$__ci_log"
    __ci_label=
  }
  __ci_table() {
    local status=$?
    set +e
    if [ -n "$__ci_label" ]; then
      # Still running when the shell exited: this is the command that failed.
      local secs
      secs="$(awk -v a="$__ci_start" -v b="$(__ci_now)" 'BEGIN { printf "%.1f", b - a }')"
      printf '%s\t%s\t%s\n' "$secs" FAILED "$__ci_label" >> "$__ci_rows"
      if [ "$__ci_verbose" != 1 ]; then
        printf '== FAILED (exit %s, %ss): %s\n' "$status" "$secs" "$__ci_label"
        cat "$__ci_log"
      fi
    fi
    rm -f "$__ci_log"
    local table
    table="$(sort -t "$(printf '\t')" -k1,1nr "$__ci_rows" |
      awk -F '\t' '{ total += $1; printf "%9s  %s%s\n", $1, ($2 == "FAILED" ? "FAILED  " : ""), $3 }
                   END { printf "%9.1f  total\n", total }')"
    printf '\n== check timings (seconds  command), slowest first\n%s\n' "$table"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { printf '### Check timings\n\n```\n%s\n```\n' "$table"; } >> "$GITHUB_STEP_SUMMARY"
    fi
    rm -f "$__ci_rows"
    return "$status"
  }
  # A `# ci:parallel begin [N]` ... `# ci:parallel end` group: each command runs in its own subshell (so it
  # sees the shell's variables, and its own `cd` or `set` stays in it), at most N at a time (default
  # CI_PARALLEL_JOBS, then 3), with stdout and stderr in a log. __ci_par_end replays the logs in input order,
  # records one timing row per command, and fails with the first failed command's status.
  __ci_par_dir=
  __ci_par_n=0
  __ci_par_live=0
  __ci_par_max=3
  __ci_par_labels=()
  __ci_par_begin() {
    __ci_par_max="${1:-${CI_PARALLEL_JOBS:-3}}"
    __ci_par_dir="$(mktemp -d)"
    __ci_par_n=0
    __ci_par_live=0
    __ci_par_labels=()
  }
  __ci_par_run() {
    local i=$__ci_par_n
    __ci_par_n=$((i + 1))
    __ci_par_labels[$i]="$1"
    if [ "$__ci_par_live" -ge "$__ci_par_max" ]; then
      wait -n || true
      __ci_par_live=$((__ci_par_live - 1))
    fi
    __ci_par_live=$((__ci_par_live + 1))
    (
      local_start="$(__ci_now)"
      set +e
      ( set -e; eval "$2" ) > "$__ci_par_dir/$i.log" 2>&1
      rc=$?
      secs="$(awk -v a="$local_start" -v b="$(__ci_now)" 'BEGIN { printf "%.1f", b - a }')"
      printf '%s %s\n' "$rc" "$secs" > "$__ci_par_dir/$i.rc"
    ) &
  }
  __ci_par_end() {
    local i rc secs failed=0 first_rc=0
    wait
    for ((i = 0; i < __ci_par_n; i++)); do
      read -r rc secs < "$__ci_par_dir/$i.rc"
      if [ "$rc" = 0 ]; then
        if [ "$__ci_verbose" = 1 ]; then
          printf '::group::%s (%ss)\n' "${__ci_par_labels[$i]}" "$secs"
          cat "$__ci_par_dir/$i.log"
          printf '::endgroup::\n'
        else
          __ci_annotations "$__ci_par_dir/$i.log"
        fi
        printf '%s\t%s\t%s\n' "$secs" ok "${__ci_par_labels[$i]}" >> "$__ci_rows"
      else
        printf '== FAILED (exit %s, %ss): %s\n' "$rc" "$secs" "${__ci_par_labels[$i]}"
        cat "$__ci_par_dir/$i.log"
        printf '%s\t%s\t%s\n' "$secs" FAILED "${__ci_par_labels[$i]}" >> "$__ci_rows"
        failed=$((failed + 1))
        [ "$first_rc" = 0 ] && first_rc=$rc
      fi
    done
    rm -rf "$__ci_par_dir"
    [ "$failed" = 0 ] || return "$first_rc"
  }
  trap __ci_table EXIT
BASH

VARIABLE_ONLY = /\A(?:export\s+)?(?:\w+=(?:"[^"]*"|'[^']*'|\S*)\s*)+\z/

# CI_SKIP_MUTANTS=1 (pull requests, docs/ci.md) drops the `*_mutation_check.rb` commands and the
# `*_MUTANTS=1` switches, leaving each fixture check itself; master and the merge queue run them all.
MUTATION_SCRIPT = /_mutation_check\.rb\b/
MUTANT_SWITCH = /\b\w*_MUTANTS=1\s+/

def without_mutants(line)
  return nil if MUTATION_SCRIPT.match?(line)

  line.gsub(MUTANT_SWITCH, '')
end

# Opt-in concurrency (docs/ci.md, "Parallel groups"): the commands between these two comment lines run
# at the same time. They are comments, so a block that is not run through this script just runs them in order.
PARALLEL_BEGIN = /\A#\s*ci:parallel\s+begin(?:\s+(\d+))?\z/
PARALLEL_END = /\A#\s*ci:parallel\s+end\z/

# Joins `\` continuations and drops comments and blanks (the two parallel markers stay).
def commands(text)
  joined = text.gsub(/\\\n/, ' ')
  joined.lines.map(&:strip).reject do |line|
    line.empty? || (line.start_with?('#') && !PARALLEL_BEGIN.match?(line) && !PARALLEL_END.match?(line))
  end
end

# The command as a reader wants to see it: without a trailing `# note`.
def label(line)
  line.sub(/\s+#\s.*\z/, '')
end

puts PRELUDE
skip_mutants = ENV['CI_SKIP_MUTANTS'] == '1'
in_group = false
commands($stdin.read).each do |line|
  if (begin_marker = PARALLEL_BEGIN.match(line))
    abort 'timed_checks: nested "ci:parallel begin"' if in_group

    in_group = true
    puts "__ci_par_begin#{begin_marker[1] ? " #{begin_marker[1]}" : ''}"
    next
  elsif PARALLEL_END.match?(line)
    abort 'timed_checks: "ci:parallel end" without a begin' unless in_group

    in_group = false
    puts '__ci_par_end'
    next
  end
  if skip_mutants
    stripped = without_mutants(line)
    puts "echo #{Shellwords.escape("skipping mutants: #{label(line)}")}" if stripped.nil? || stripped != line
    next if stripped.nil?

    line = stripped
  end
  if VARIABLE_ONLY.match?(line)
    abort "timed_checks: a variable assignment inside a ci:parallel group would not reach the later commands: #{line}" if in_group

    puts line
  elsif in_group
    puts "__ci_par_run #{Shellwords.escape(label(line))} #{Shellwords.escape(line)}"
  else
    # A brace group, not a subshell: the command still runs in the step's own shell.
    puts "__ci_begin #{Shellwords.escape(label(line))}", "{ #{line}", '} >&4 2>&1', '__ci_end'
  end
end
abort 'timed_checks: "ci:parallel begin" without an end' if in_group
