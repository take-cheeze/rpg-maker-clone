#!/usr/bin/env ruby
# Check the runtime-log capture that feeds the copyable error report.
#
# RGSS::ErrorReport tees $stderr into a bounded ring buffer so a crash report
# can carry the `[RPG2k]` / `[RGSS]` lines that led up to the failure (see
# mruby-rgss/mrblib/error_report.rb and src/error_dump.cxx). Its whole job is
# bookkeeping — buffering partial writes, bounding the buffer, forwarding every
# write untouched — which is exactly the kind of thing that breaks silently:
# a dropped forward would swallow the game's log, and an unbounded buffer would
# leak for as long as the game runs.
#
# The file is plain Ruby with no mruby dependencies, so this runs it on CRuby
# and needs no engine build. The same behaviour is asserted inside the built
# interpreter by mruby-rgss/test/test.rb (the mruby_test ctest).
#
# Usage: ruby scripts/error_report_check.rb

require 'stringio'

require_relative '../mruby-rgss/mrblib/error_report'

failures = []

def check(failures, name)
  yield
  puts "ok - #{name}"
rescue StandardError => e
  failures << "#{name}: #{e.message}"
  warn "FAIL - #{name}: #{e.message}"
end

def assert(cond, message = 'assertion failed')
  raise message unless cond
end

def assert_equal(expected, actual)
  raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

report = RGSS::ErrorReport

check(failures, 'whole lines are recorded and read back in order') do
  report.clear
  report.record("[RPG2k] first\n")
  report.record("[RPG2k] second\n")
  assert_equal ['[RPG2k] first', '[RPG2k] second'], report.lines
  assert_equal "[RPG2k] first\n[RPG2k] second\n", report.log_tail
end

check(failures, 'a line split across writes is joined') do
  report.clear
  report.record('[RGSS] half ')
  report.record("and half\n")
  assert_equal ['[RGSS] half and half'], report.lines
end

check(failures, 'an unterminated trailing write still reaches the tail') do
  # The last thing a dying runtime logs is often exactly the interesting line,
  # and it may never get its newline. It must not be swallowed.
  report.clear
  report.record("done\n")
  report.record('in progress')
  assert_equal ['done'], report.lines
  assert_equal "done\nin progress\n", report.log_tail
end

check(failures, 'the buffer is bounded to MAX_LINES') do
  report.clear
  (RGSS::ErrorReport::MAX_LINES + 50).times { |i| report.record("line #{i}\n") }
  assert_equal RGSS::ErrorReport::MAX_LINES, report.lines.size
  assert_equal 'line 50', report.lines.first
  assert_equal "line #{RGSS::ErrorReport::MAX_LINES + 49}", report.lines.last
end

check(failures, 'log_tail honours a smaller limit') do
  report.clear
  5.times { |i| report.record("line #{i}\n") }
  assert_equal "line 3\nline 4\n", report.log_tail(2)
end

check(failures, 'a runaway line is truncated') do
  report.clear
  report.record('x' * (RGSS::ErrorReport::MAX_LINE_CHARS + 100) + "\n")
  assert_equal RGSS::ErrorReport::MAX_LINE_CHARS + 3, report.lines.first.size
  assert report.lines.first.end_with?('...'), 'truncation is not marked'
end

check(failures, 'log_tail is empty when nothing was recorded') do
  report.clear
  assert_equal '', report.log_tail
end

check(failures, 'the tee forwards every write to the real $stderr') do
  report.clear
  sink = StringIO.new
  tee = RGSS::ErrorReport::Tee.new(sink)
  tee.puts '[RPG2k] via puts'
  tee.print '[RPG2k] via print'
  tee.print "\n"
  tee.write "[RPG2k] via write\n"
  tee << "[RPG2k] via shovel\n"
  expected = "[RPG2k] via puts\n[RPG2k] via print\n" \
             "[RPG2k] via write\n[RPG2k] via shovel\n"
  assert_equal expected, sink.string
  assert_equal expected, report.log_tail
end

check(failures, 'puts records what IO#puts writes') do
  report.clear
  sink = StringIO.new
  tee = RGSS::ErrorReport::Tee.new(sink)
  tee.puts                         # a bare newline
  tee.puts "already terminated\n"  # not given a second newline
  tee.puts 'a', 'b'                # one line each
  tee.puts ['c', 'd']              # arrays are flattened
  assert_equal sink.string, report.log_tail
end

check(failures, 'the tee delegates the rest of the IO surface') do
  sink = StringIO.new
  tee = RGSS::ErrorReport::Tee.new(sink)
  tee.flush
  assert tee.respond_to?(:flush), 'delegated methods are not answered by respond_to?'
  assert_equal sink, tee.io
end

check(failures, 'probe! logs its marker line and then raises') do
  # What the engine's --error_dump_probe assumes when it reads a report back
  # (error_dump_run_probe in src/error_dump.cxx).
  report.clear
  sink = StringIO.new
  tee = RGSS::ErrorReport::Tee.new(sink)
  raised = nil
  begin
    original = $stderr
    $stderr = tee
    begin
      RGSS::ErrorReport.probe!
    rescue RuntimeError => e
      raised = e
    end
  ensure
    $stderr = original
  end
  assert_equal RGSS::ErrorReport::PROBE_MESSAGE, raised && raised.message
  assert_equal [RGSS::ErrorReport::PROBE_LOG_LINE], report.lines
  assert raised.backtrace.any? { |f| f.include?('probe_raise') },
         'probe! does not raise from a nested frame'
end

check(failures, 'install tees $stderr exactly once') do
  report.clear
  original = $stderr
  begin
    assert RGSS::ErrorReport.install, 'the first install did not report installing'
    assert $stderr.is_a?(RGSS::ErrorReport::Tee), '$stderr was not teed'
    teed = $stderr
    assert_equal false, RGSS::ErrorReport.install
    assert teed.equal?($stderr), 'a second install stacked another tee'
    assert RGSS::ErrorReport.installed?
    $stderr.puts '[RPG2k] through the installed tee'
    assert_equal ['[RPG2k] through the installed tee'], report.lines
  ensure
    $stderr = original
  end
end

if failures.empty?
  puts "error report: #{RGSS::ErrorReport::MAX_LINES}-line log capture — OK"
  exit 0
end

warn ''
failures.each { |f| warn "failed: #{f}" }
abort 'RGSS::ErrorReport log capture is broken'
