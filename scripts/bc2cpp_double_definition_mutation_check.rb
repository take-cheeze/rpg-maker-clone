#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the double-definition pass (docs/adr/0319). Each mutant is a copy of tools/bc2cpp, placed
# inside the repository so its own ../.. is the repository root (the closed world reads the build's sources
# from there; a copy elsewhere sees an empty world and every mutant would die for the wrong reason), with one
# condition removed. scripts/bc2cpp_double_definition_check.rb (DD_MODE=static) run against the mutant must
# FAIL on the check that guards the condition. An unmutated control run must pass, and must show that the
# generated-code assertions ran (a run that checks nothing would pass too).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_double_definition_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'bc2cpp_mutant_pool'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, [[file, pattern, replacement], ...], check label that must FAIL]
MUTANTS = [
  ['the first definition is kept instead of the last',
   [['double_definitions.rb', 'last = group.last', 'last = group.first'],
    ['double_definitions.rb', 'group[0...-1].each { |d| gone << d }', 'group[1..].each { |d| gone << d }']],
   /the kept def is the last one|def_then_def: one body|reopened_class/],
  ['the earlier definitions are not dropped',
   [['double_definitions.rb', 'group[0...-1].each { |d| gone << d }', 'nil']],
   /left with two definitions|keeps one definition|every _impl is defined once/],
  ['a conditional last definition is trusted',
   [['double_definitions.rb', 'if group.any?(&:site) || last.conditional', 'if group.any?(&:site)']],
   /conditional/],
  ['a loop-installed accessor is given a position',
   [['double_definitions.rb', 'if group.any?(&:site) || last.conditional', 'if last.conditional']],
   /loop-installed/],
  ['a forward jump does not make a definition conditional',
   [['double_definitions.rb', 'spans.any? { |from, to| from < addr && addr < to }', 'false']],
   /conditional/],
  ['an alias is not a later definition',
   [['registry.rb', 'registry[mname].none? { |d| d.owner == owner }', 'true']],
   /alias/],
  ['an undef is not a later definition', [['registry.rb', "when 'UNDEF'", "when 'UNDEF_NOT'"]], /undef of f/],
  ['alias_method is not a later definition',
   [['registry.rb', "%w[alias_method undef_method remove_method].include?(name) &&", "%w[undef_method remove_method].include?(name) &&"]],
   /alias\/alias_method\/undef of e|alias_over_def/],
  ['private applies to the first definition, not the latest',
   [['registry.rb', 'registry[mname]&.reverse_each&.find', 'registry[mname]&.find']], /private :p2/],
  ['a module_function copy of a replaced body is kept',
   [['double_definitions.rb', 'dead.include?(d.copy_irep)', 'false']], /module_function copy/],
  ['clashing C++ spellings are left alone',
   [['double_definitions.rb', 'pairs.drop(1).each_with_index', '[].each_with_index']],
   /second of two clashing pairs|distinct symbols|get distinct symbols|every _impl is defined once/],
  ['the suffix is computed and not used',
   [['codegen.rb', 'suffix ? "#{base}#{suffix}" : base', 'base']], /distinct symbols|every _impl is defined once/],
  ['the pass is not run',
   [['bc2cpp.rb', 'double_definitions = DoubleDefinitions.settle(registry)',
     'double_definitions = DoubleDefinitions::Report.new(dropped: [], withdrawn: [])']],
   /every _impl is defined once|one body|registered twice/]
].freeze

run_check = lambda do |tool_dir|
  env = { 'DD_TOOL_DIR' => tool_dir, 'DD_MODE' => 'static', 'MRBC' => ENV.fetch('MRBC') }
  [env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_double_definition_check.rb')]]
end

mutate = lambda do |(_name, edits, expected)|
  # Inside the repo, so the copy's own ../.. is the repo root.
  Dir.mktmpdir('.ddmut', ROOT) do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    missing = edits.reject do |file, pattern, replacement|
      path = File.join(dir, 'bc2cpp', file)
      text = File.read(path)
      text.include?(pattern) && File.write(path, text.sub(pattern) { replacement })
    end
    next :gone unless missing.empty?

    env, argv = run_check.call(File.join(dir, 'bc2cpp'))
    Bc2cppMutantPool.run(env, argv, stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

failures = []
control = Dir.mktmpdir('.ddmut', ROOT) do |dir|
  FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
  env, argv = run_check.call(File.join(dir, 'bc2cpp'))
  Bc2cppMutantPool.run(env, argv)
end
puts "  #{control.success ? 'ok  ' : 'FAIL'} control: the unmutated copy passes"
unless control.success
  puts control.out.lines.grep(/FAIL|rror/).first(8).join
  failures << 'control'
end
ran = control.out.include?('def_then_def: one body, the last (returns 2)') && control.out.scan(/^  ok /).size > 80
puts "  #{ran ? 'ok  ' : 'FAIL'} control: the generated-code assertions ran (#{control.out.scan(/^  ok /).size} checks)"
failures << 'control ran nothing' unless ran

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, edits, expected), run|
  if run == :gone
    puts "  FAIL #{name}: a mutation site is gone from #{edits.map(&:first).uniq.join(', ')}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    failures << name
  end
end

if failures.empty?
  puts "bc2cpp double definition mutation check: PASS (#{MUTANTS.size} mutants killed, control passes)"
else
  warn "bc2cpp double definition mutation check: #{failures.size} failure(s)"
  exit 1
end
