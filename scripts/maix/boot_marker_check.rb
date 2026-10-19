#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-test for scripts/maix/boot_marker.rb, run through its CLI the same way
# the maix-smoke job runs it: a log with the marker on its own line passes, a
# log with a Renode [WARNING] record spliced into the marker passes, and a log
# without the marker fails.
#
# Usage: ruby scripts/maix/boot_marker_check.rb

require 'open3'
require 'rbconfig'

ROOT = File.expand_path('../..', __dir__)
CLI = File.join(ROOT, 'scripts/maix/boot_marker.rb')
MARKER = 'REACHED loop()'

CASES = {
  'marker on its own line' => ["boot\n=== REACHED setup() ===\n=== REACHED loop() ===\n", 0],
  'marker split by a [WARNING] record' =>
    ["boot\n=== REACHED setup() ===\n=== REACHED 00:00:01.250 [WARNING] cpu1: spurious\nloop() ===\n", 0],
  'no marker in log' =>
    ["boot\n=== REACHED setup() ===\n00:00:01.250 [WARNING] cpu1: spurious\n", 1]
}.freeze

failures = []
CASES.each do |name, (log, expected)|
  _stdout, stderr, status = Open3.capture3(RbConfig.ruby, CLI, '-', MARKER, stdin_data: log)
  actual = status.exitstatus
  ok = actual == expected
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}: exit #{actual} (expected #{expected})"
  puts "       #{stderr.strip}" unless stderr.empty?
  failures << name unless ok
end

unless failures.empty?
  warn "maix boot marker check: #{failures.size} case(s) failed: #{failures.join(', ')}"
  exit 1
end
puts 'maix boot marker check: ok'
