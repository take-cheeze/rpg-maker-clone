#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns a workflow `checks:` block (one shell command per line, read from stdin) into a bash script
# that runs the same commands, in the same shell and order, and ends with a "seconds  command"
# table sorted slowest first (docs/ci.md, "Timing table").
#
#   ruby scripts/ci_timed_checks.rb > "$RUNNER_TEMP/checks.sh" <<'CHECKS'
#   ...the checks block...
#   CHECKS
#   source "$RUNNER_TEMP/checks.sh"
#
# The commands are not rewritten, only bracketed by __ci_begin/__ci_end, so a failing one still
# aborts the step under `set -e` with its own status. An EXIT trap prints the table on success and on
# failure alike (the command that failed is listed as FAILED with the time it ran).
#
# Comment lines and blank lines are dropped; a `\` continuation is joined. Lines that only set shell
# variables (`width=...`, `export A=b`) are passed through untimed, since later commands rely on them.
require 'shellwords'

PRELUDE = <<~'BASH'
  __ci_rows="$(mktemp)"
  __ci_label=
  __ci_start=
  __ci_now() { date +%s.%N; }
  __ci_begin() { __ci_label="$1"; __ci_start="$(__ci_now)"; }
  __ci_end() {
    local secs
    secs="$(awk -v a="$__ci_start" -v b="$(__ci_now)" 'BEGIN { printf "%.1f", b - a }')"
    printf '%s\t%s\t%s\n' "$secs" ok "$__ci_label" >> "$__ci_rows"
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
    fi
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

# Joins `\` continuations and drops comments and blanks.
def commands(text)
  joined = text.gsub(/\\\n/, ' ')
  joined.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
end

# The command as a reader wants to see it: without a trailing `# note`.
def label(line)
  line.sub(/\s+#\s.*\z/, '')
end

puts PRELUDE
skip_mutants = ENV['CI_SKIP_MUTANTS'] == '1'
commands($stdin.read).each do |line|
  if skip_mutants
    stripped = without_mutants(line)
    puts "echo #{Shellwords.escape("skipping mutants: #{label(line)}")}" if stripped.nil? || stripped != line
    next if stripped.nil?

    line = stripped
  end
  if VARIABLE_ONLY.match?(line)
    puts line
  else
    puts "__ci_begin #{Shellwords.escape(label(line))}", line, '__ci_end'
  end
end
