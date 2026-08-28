#!/usr/bin/env ruby
# encoding: UTF-8
#
# Regression guard for per-frame mruby object churn on the RPG2000 map scene.
#
# Why this exists: a string of fixes (skip_to's terminator arrays hoisted to
# frozen constants; Scene::Map#events_dirty?/#record_map_event_positions
# reusing Arrays instead of rebuilding them every frame; #step_parallels and
# four other @events.each loops rewritten as block-free while loops;
# Game::Interpreter#range returning a Range instead of a throwaway Array;
# Array#include? given a native-equivalent override because mruby's own falls
# through to a block-allocating Enumerable#include?) cut this scene's
# per-frame Array/Proc/env allocation by well over half over several rounds,
# each one found by hand with a temporary instrumentation pass and reverted
# before commit. None of that is guarded against silently regressing -- a
# reverted fix, a new per-frame `.each { }` on @events, a new `[a, b]`-style
# throwaway array in a hot command handler -- would show up as nothing but a
# quieter frame budget until the fix's own PR reads like ancient history.
#
# This script is the standing version of that same manual pass: it boots the
# real engine against a real game, samples RGSS::Profiler's own per-type
# cumulative allocation counters (mirrored into the Chrome trace as the
# `mruby_type_allocs` counter series -- see mruby-rgss/src/profiler.cxx and
# README.md's Profiling section) at two points in a steady window, and fails
# if the measured per-second rate for Array, Proc or env exceeds a ceiling
# generously above what this scene measures today. It is a floor for "did
# something make this a lot worse", not a tight bound -- a genuine new
# per-frame feature can legitimately raise the true number, in which case
# re-run with `--report` to see the fresh rates and raise CEILINGS to match,
# with a comment saying why.
#
# Usage:
#   ruby scripts/rpg2k_alloc_regression_check.rb [GAME_DIR] [--report]
#     GAME_DIR   defaults to data/Nepheshel206beta/Nepheshel206Rbeta
#     --report   print the measured rates and exit 0 regardless of the
#                ceilings, for re-baselining after a deliberate change
#
# Env vars (mirroring the other boot-check scripts):
#   ENGINE               path to the built binary (default ./build/rpg_maker_clone)
#   SERVER_NUM            xvfb-run --server-num to use (default 122; see the
#                         reserved display numbers in .github/workflows/build.yml)
#   RPG2K_ALLOC_TIMEOUT_MS how long to let the engine run (default 25000)
#
# Exits non-zero if the build is missing, the game data is missing, the trace
# came back with fewer than two samples, or a measured rate exceeds its ceiling.

require 'json'
require 'tmpdir'

ENGINE = ENV['ENGINE'] || './build/rpg_maker_clone'
SERVER_NUM = ENV['SERVER_NUM'] || '122'
TIMEOUT_MS = (ENV['RPG2K_ALLOC_TIMEOUT_MS'] || '25000').to_i

report_only = ARGV.delete('--report') ? true : false
game_dir = ARGV[0] || 'data/Nepheshel206beta/Nepheshel206Rbeta'

# Ceilings in allocations/second, ~1.1-1.15x the steady-state rate this scene
# actually measures on Nepheshel's scripted opening with every fix above
# applied (docs/profiling.md's own baseline run: Array ~4000/s, Proc ~1650/s,
# env ~985/s, stable within 1% run to run). Checked against reverting just
# the Array#include? fix (Array 4496/s, Proc 2008/s, env 1347/s) and against
# reverting this whole round -- #range's Array fix included (Array 4692/s,
# Proc 2228/s, env 1574/s): margins this tight catch either, with enough
# slack above the measured baseline's own <1% run-to-run variance that a
# clean tree does not flap. Only the three types this investigation was
# about; the same `mruby_type_allocs` sample carries every type
# RGSS::Profiler tracks, for `--report`'s sake.
CEILINGS = { 'Array' => 4500.0, 'Proc' => 1900.0, 'env' => 1140.0 }.freeze

unless File.executable?(ENGINE)
  warn "error: #{ENGINE} not built; run cmake --build build first"
  exit 1
end

unless File.exist?(File.join(game_dir, 'RPG_RT.ldb'))
  puts "skip: no RPG_RT.ldb under #{game_dir} (run scripts/download-nepheshel.bash first)"
  exit 0
end

Dir.mktmpdir('rpg2k_alloc_regression') do |dir|
  trace_path = File.join(dir, 'trace.json')
  cmd = ['xvfb-run', "--server-num=#{SERVER_NUM}",
         ENGINE, '--test_play', '--profile', '--profile_interval_ms=2000',
         "--profile_trace=#{trace_path}", "--timeout_ms=#{TIMEOUT_MS}",
         '--game_dir', game_dir, '--rpg2k_new_game']
  ok = system({ 'SDL_AUDIODRIVER' => 'dummy' }, *cmd, out: File::NULL, err: File::NULL)
  unless File.exist?(trace_path)
    warn "error: no trace produced -- the engine failed to start " \
         "(exit status: #{ok.inspect}); run the command by hand to see why:\n" \
         "  SDL_AUDIODRIVER=dummy xvfb-run --server-num=#{SERVER_NUM} #{ENGINE} " \
         "--test_play --profile --profile_trace=#{trace_path} --game_dir #{game_dir} --rpg2k_new_game"
    exit 1
  end

  # The trace stream stays loadable even if the process was killed mid-run
  # (README.md's Profiling section documents this deliberately: no trailing
  # `]` is guaranteed) -- append one if it is missing rather than treat that
  # as a parse error.
  content = File.read(trace_path).rstrip
  content = content[0..-2] if content.end_with?(',')
  content += ']' unless content.end_with?(']')
  events = JSON.parse(content)

  samples = events.select { |e| e['name'] == 'mruby_type_allocs' }
  if samples.size < 3
    warn "error: only #{samples.size} mruby_type_allocs sample(s) captured -- " \
         "raise RPG2K_ALLOC_TIMEOUT_MS or lower --profile_interval_ms"
    exit 1
  end

  # Drop the first sample: it covers the load-time burst (asset decode, the
  # title -> map transition), not steady per-frame gameplay churn -- the same
  # caveat every manual capture in this investigation noted by hand.
  first = samples[1]
  last = samples[-1]
  elapsed_s = (last['ts'] - first['ts']) / 1_000_000.0

  puts "measured over #{elapsed_s.round(1)}s (#{samples.size - 1} steady samples):"
  failures = []
  CEILINGS.each do |type, ceiling|
    delta = (last['args'][type] || 0) - (first['args'][type] || 0)
    rate = delta / elapsed_s
    over = rate > ceiling
    failures << type if over && !report_only
    status = over ? 'FAIL' : '  ok'
    puts format('  %s %-6s %8.1f/s  (ceiling %.0f/s)', status, type, rate, ceiling)
  end

  if report_only
    puts 'report only -- not asserting against ceilings'
  elsif failures.empty?
    puts 'OK: per-frame object churn within bounds'
  else
    warn "FAILED: allocation regression in #{failures.join(', ')} -- " \
         "re-run with --report, then either find and fix the reverted/missing " \
         "optimization (see this file's own header for the fixes it guards) " \
         "or, if the increase is a genuine reviewed one (a new per-frame " \
         "feature), raise its CEILINGS entry here with a comment saying why."
    exit 1
  end
end
