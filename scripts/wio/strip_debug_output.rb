#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step: strips $stderr.puts diagnostic statements out of a
# copy of a .rb file before it reaches mrbc, the same way ADR 115/117/118
# already strip mrbc/cc debug metadata -- these are unobservable on
# env:wio_rgss_boot today (no serial console wired up) but still cost real
# flash (a string-literal pool entry plus call/dispatch opcodes per site).
#
# Deliberately not a regex/sed pass: this codebase has real multi-line
# $stderr.puts calls joined by a trailing `\` (e.g.
# mruby-rpg2k/mrblib/interpreter.rb's "this event" has no map event"
# message), which a naive "strip matching lines" script would either miss
# or leave a dangling half-statement in. Uses Ripper (stdlib -- this
# project has no existing Gemfile/gem dependency to lean on `parser`/
# rubocop-ast for) two ways: to find each $stderr.puts call by real GVAR
# token, not a text match (so a string that merely *contains* the text
# "$stderr.puts" is never touched), and to verify the rewritten source
# still parses before accepting it -- if anything about a call's shape
# isn't recognized, this leaves it alone rather than risk corrupting it.
#
# Usage: ruby strip_wio_debug_output.rb <input.rb> <output.rb>

require "ripper"

def find_stmt_removals(source)
  tokens = Ripper.lex(source)
  lines = source.split("\n", -1)
  removals = []

  i = 0
  while i < tokens.length
    (pos, type, str, *) = tokens[i]
    if type == :on_gvar && str == "$stderr"
      j = i + 1
      j += 1 while j < tokens.length && tokens[j][1] == :on_sp
      if j < tokens.length && tokens[j][1] == :on_period
        j += 1
        j += 1 while j < tokens.length && tokens[j][1] == :on_sp
        if j < tokens.length && tokens[j][1] == :on_ident && tokens[j][2] == "puts"
          line_idx = pos[0] - 1
          before = lines[line_idx][0...pos[1]]
          # Only remove when $stderr is the first thing on its line (a bare
          # statement) -- a call folded into a larger expression (a block
          # body on the same line as other code, say) is left alone; the
          # one such case in this codebase today is inside scene/battle.rb,
          # already excluded from wio's own rbfiles entirely (ADR 107).
          if before.strip.empty?
            end_line = line_idx
            end_line += 1 while end_line < lines.length - 1 && lines[end_line].end_with?("\\")
            removals << (line_idx..end_line)
          end
        end
      end
    end
    i += 1
  end

  removals
end

def strip_debug_output(source)
  removals = find_stmt_removals(source)
  return source if removals.empty?

  lines = source.split("\n", -1)
  removed_lines = Array.new(lines.length, false)
  removals.each { |range| range.each { |i| removed_lines[i] = true } }

  kept = lines.each_with_index.reject { |_, i| removed_lines[i] }.map(&:first)
  # split("\n", -1) keeps a trailing "" element for a source that ends in a
  # newline; join always re-adds the separator between kept lines, so a
  # trailing "" produces the file's own final newline back correctly.
  kept.join("\n")
end

if __FILE__ == $PROGRAM_NAME
  in_path, out_path = ARGV
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <input.rb> <output.rb>" unless in_path && out_path

  source = File.read(in_path, external_encoding: Encoding::UTF_8)
  rewritten = strip_debug_output(source)

  # The hard safety net: never ship a rewrite that doesn't parse. Ripper.sexp
  # returns nil on a syntax error rather than raising, for both directions --
  # also refuses to "fix" a file that didn't parse correctly to begin with.
  if Ripper.sexp(source) && !Ripper.sexp(rewritten)
    raise "strip_wio_debug_output: rewrite of #{in_path} does not parse; " \
          "leaving the original untouched"
  end

  File.write(out_path, rewritten)
end
