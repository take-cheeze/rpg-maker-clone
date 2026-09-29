#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check ADR 0262: a "should not happen" path is an error, not a silent fallback.
# Pure CRuby, no mrbc needed.
#
#   - compiler: an outside source that exists but cannot be read raises, a
#     missing one is skipped with one stderr line, and an unknown constant-proof
#     kind or opcode raises instead of quietly answering "not proven";
#   - runtime Ruby (mruby-rpg2k/lcf/rgss mrblib): every `rescue` that catches
#     StandardError (or everything) reports to $stderr / RGSS.warn_once, and no
#     `rescue` modifier remains. A narrower class needs no report (NameError for
#     a launcher constant a host harness never defines).
#
#   ruby scripts/impossible_as_error_check.rb

require 'stringio'
require 'tmpdir'
require 'set'
require_relative '../tools/bc2cpp/source_text'
require_relative '../tools/bc2cpp/integer_constants'

root = File.expand_path('..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def capture_stderr
  saved = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = saved
end

puts '== SourceText'
Dir.mktmpdir do |dir|
  present = File.join(dir, 'a.rb')
  File.write(present, "FOO = 1\nBAR = 2\n")
  missing = File.join(dir, 'gone.rb')
  SourceText.forget_warnings

  result = nil
  err = capture_stderr do
    2.times { result = SourceText.read(missing, 'probe') }
  end
  check.call('a missing path reads as nil', result.nil?)
  check.call('a missing path is reported once, tagged [bc2cpp]',
             err.lines.size == 1 && err.start_with?('[bc2cpp] probe: ') && err.include?(missing))
  check.call('a present path reads its text', SourceText.read(present, 'probe') == "FOO = 1\nBAR = 2\n")

  raised = begin
    SourceText.read(dir, 'probe')
    nil
  rescue SourceText::Unreadable => e
    e
  end
  check.call('an existing but unreadable path (a directory) raises with the reader and path',
             raised && raised.message.include?('probe') && raised.message.include?(dir))

  names = nil
  capture_stderr { names = IntegerConstants.foreign_const_names([missing, present]) }
  check.call('a poison scan skips the missing file and still reads the rest', names == Set['FOO', 'BAR'])
  scan_raised = begin
    IntegerConstants.foreign_const_names([dir])
    false
  rescue SourceText::Unreadable
    true
  end
  check.call('a poison scan does not under-collect past an unreadable file', scan_raised)
end

puts '== IntegerConstants invariants'
raises = lambda do |klass, &block|
  block.call
  false
rescue klass
  true
end
check.call('a well-formed literal kind is integral', IntegerConstants.integral_kind?(:literal, Set.new))
check.call('an unknown definition kind raises', raises.call(ArgumentError) { IntegerConstants.integral_kind?([:bogus, 1], Set.new) })
check.call('an unknown operand kind raises', raises.call(ArgumentError) { IntegerConstants.integral_operand?([:bogus], Set.new) })
check.call('an unknown definition kind raises when valued', raises.call(ArgumentError) { IntegerConstants.value_for_kind([:bogus], [], nil) })
check.call('an unknown arithmetic opcode raises',
           raises.call(ArgumentError) { IntegerConstants.value_for_kind([:arithmetic, 'MUL', [:literal, 2], [:literal, 3]], [], nil) })
check.call('a literal still has its value', IntegerConstants.value_for_kind([:literal, 7], [], nil) == 7)

puts '== runtime rescues'
RESCUE = /^(\s*)rescue\b(.*)$/
MODIFIER = /\S\s+rescue\s+(?:nil|false|true|\d+|''|"")(?=[\s);,]|$)/
broad = lambda do |classes|
  list = classes.sub(/=>.*/, '').split(',').map(&:strip).reject(&:empty?)
  list.empty? || list.include?('StandardError') || list.include?('Exception')
end
reports = /\$stderr|\bwarn\b|warn_once|\braise\b/

silent = []
modifiers = []
Dir[File.join(root, '{mruby-rpg2k,mruby-lcf,mruby-rgss}/mrblib/**/*.rb')].sort.each do |path|
  lines = File.readlines(path)
  lines.each_with_index do |line, i|
    next if line.lstrip.start_with?('#')

    modifiers << "#{path.delete_prefix("#{root}/")}:#{i + 1}" if line.match?(MODIFIER)
    m = line.match(RESCUE) or next
    next unless broad.call(m[2])

    indent = m[1].size
    body = lines[(i + 1)..].take_while { |l| l.strip.empty? || l[/\A\s*/].size > indent }
    silent << "#{path.delete_prefix("#{root}/")}:#{i + 1}" unless (m[2] + body.join).match?(reports)
  end
end
check.call("no broad rescue recovers silently (found #{silent.size}: #{silent.first(5).join(', ')})", silent.empty?)
check.call("no `rescue` modifier remains (found #{modifiers.size}: #{modifiers.first(5).join(', ')})", modifiers.empty?)

if failures.empty?
  puts 'impossible-as-error check: PASS'
else
  warn "impossible-as-error check: #{failures.size} failure(s)"
  exit 1
end
