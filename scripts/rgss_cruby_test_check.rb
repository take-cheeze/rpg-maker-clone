#!/usr/bin/env ruby
# encoding: UTF-8
#
# Run the mruby-rgss test suite (mruby-rgss/test/test.rb) under plain CRuby.
#
# In the normal build that suite runs inside a built mruby (the `mruby_test`
# ctest), which needs the whole toolchain and cannot see the CRuby stdlib. This
# harness stands in for the engine with the CRuby compatibility layer
# (scripts/rgss_cruby_compat.rb), loads the *real* mrblib sources on top of it,
# and runs the same test file — so the suite guards the RGSS behavioural
# contract (value-type clamping and Marshal, the pixel-blit arithmetic, the
# image loaders, the Input frame machine, Graphics/Audio/Profiler) with no
# mruby build, and scripts/coverage_report.rb can measure the mrblib lines the
# suite reaches.
#
# The rule is the one every *-check harness follows: our own Ruby is always
# loaded for real; only native code is stood in for (here by the compat layer,
# whose C arithmetic is itself pinned by the suite it loads).
#
# Usage:
#   ruby scripts/rgss_cruby_test_check.rb
# Exits non-zero if any assertion fails.

require "tmpdir"
require_relative "rgss_cruby_compat"

failures = []
$rgss_check_failures = failures

# One test asserts that an upper-case extension on disk resolves exactly as
# written — a property only a case-sensitive filesystem has (Linux CI's ext4).
# On a case-insensitive volume (macOS's default APFS, Windows) the lower-case
# candidate legitimately matches first and the native suite fails there too, so
# skip it rather than report a false regression.
CASE_SENSITIVE = begin
  probe = "rgss-cruby-case-probe"
  File.binwrite(probe, "")
  sensitive = !File.exist?(probe.upcase)
  File.delete(probe)
  sensitive
end

SKIP_ON_CASE_INSENSITIVE = {
  "RGSS::Audio finds an upper-case extension on disk" =>
    "needs a case-sensitive filesystem"
}.freeze

# --- mrbtest's assert API, as test/test.rb uses it ---------------------------

def assert(message)
  if SKIP_ON_CASE_INSENSITIVE.key?(message) && !CASE_SENSITIVE
    puts "SKIP - #{message} (#{SKIP_ON_CASE_INSENSITIVE[message]})"
    return
  end
  yield
  puts "ok - #{message}"
rescue StandardError => e
  $rgss_check_failures << "#{message}: #{e.message}"
  warn "FAIL - #{message}: #{e.message}"
end

def assert_equal(expected, actual, message = nil)
  return if expected == actual
  raise message || "expected #{expected.inspect}, got #{actual.inspect}"
end

def assert_not_equal(unexpected, actual, message = nil)
  return unless unexpected == actual
  raise message || "expected #{unexpected.inspect} != #{actual.inspect}"
end

def assert_true(cond, message = nil)
  return if cond
  raise message || "expected true, got #{cond.inspect}"
end

def assert_false(cond, message = nil)
  return unless cond
  raise message || "expected false, got #{cond.inspect}"
end

def assert_nil(value, message = nil)
  return if value.nil?
  raise message || "expected nil, got #{value.inspect}"
end

def assert_kind_of(cls, value, message = nil)
  return if value.is_a?(cls)
  raise message || "expected #{value.inspect} to be a #{cls}"
end

def assert_raise(exception)
  begin
    yield
  rescue exception => e
    return e
  rescue StandardError => e
    raise "expected #{exception} to be raised, got #{e.class}: #{e.message}"
  end
  raise "expected #{exception} to be raised, nothing raised"
end

# --- Load the real engine sources -------------------------------------------

mrblib = File.expand_path("../mruby-rgss/mrblib", __dir__)
load File.join(mrblib, "lib.rb")
load File.join(mrblib, "error_report.rb")

# The runtime pulls RGSS into the top level (mruby-rpgxp/mrblib/lib.rb) so a
# game's scripts use the bare names; mirror that.
class Object
  include RGSS
end
Table = RGSS::Table
Color = RGSS::Color
Tone = RGSS::Tone
Rect = RGSS::Rect

# --- Run the suite in a scratch dir so its fixture files stay out of the repo --

test_file = File.expand_path("../mruby-rgss/test/test.rb", __dir__)
Dir.mktmpdir("rgss-cruby-test") do |dir|
  Dir.chdir(dir) { load test_file }
end

if failures.empty?
  puts "OK: mruby-rgss suite passes under CRuby"
  exit 0
end

warn ""
failures.each { |f| warn "failed: #{f}" }
abort "#{failures.size} assertion(s) failed"
