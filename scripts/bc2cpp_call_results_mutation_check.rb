#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for ACCESSOR_RETURN_CLASS and EXACT_CORE_ARMS (docs/adr/0309). Each mutant is a copy of
# tools/bc2cpp with one soundness condition broken; scripts/bc2cpp_call_results_check.rb, run against the
# mutant through BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards that
# condition. A mutant that passes means the condition has no negative case.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_call_results_mutation_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a slot no constructor assigns counts as assigned (nil is dropped from the reader)', 'codegen_return_accessors.rb',
   'numeric_ivar_assured?(d.owner, d.name) ? pool : pool | NumericFlow::NIL', 'pool',
   /an unassigned slot: the send keeps its guard/],
  ['a slot with no pool counts as an empty one', 'codegen_return_accessors.rb',
   'return NumericFlow::OTHER unless pool', 'pool ||= 0',
   /NEG a writer on the ivar|NEG an instance_variable_set|NEG a store from a subclass|NEG a second class/],
  ['the accessor kill switch is ignored', 'codegen_return_accessors.rb',
   "ENV.fetch('BC2CPP_RETURN_ACCESSORS', '1') != '0'", 'true', /BC2CPP_RETURN_ACCESSORS=0/],
  ['the exact-core kill switch is ignored', 'codegen_exact_core_arms.rb',
   "ENV.fetch('BC2CPP_EXACT_CORE_ARMS', '1') != '0'", 'true', /BC2CPP_EXACT_CORE_ARMS=0/],
  ['the push arm takes any exact core class, not only Array', 'codegen_exact_core_arms.rb',
   "return nil unless exact_core_arm_class(irep, idx, reg, self_implicit) == 'Array'",
   'return nil unless exact_core_arm_class(irep, idx, reg, self_implicit)', /NEG push_hash/],
  ['the Integer-path push ignores a Ruby Array#<<', 'codegen_send.rb',
   "exact_push = builtin_class_send_safe?(name, %w[Array]) &&\n                   exact_array_push_code(",
   "exact_push = exact_array_push_code(", /a Ruby Array#<</]
].freeze

failures = []
# CR_MUTANT=text runs the mutants whose name contains it (while developing a new one).
mutants = ENV['CR_MUTANT'] ? MUTANTS.select { |m| m.first.include?(ENV['CR_MUTANT']) } : MUTANTS
mutants.each do |name, file, pattern, replacement, expected|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    unless text.include?(pattern)
      puts "  FAIL #{name}: the mutation site is gone from #{file}"
      failures << name
      next
    end
    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'CR_GENERATED_ONLY' => '1' }
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_call_results_check.rb'))
    failed_lines = out.lines.grep(/^\s+FAIL /)
    killed = !status.success? && failed_lines.any? { |l| l.match?(expected) }
    puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
    unless killed
      puts failed_lines.first(5).join
      failures << name
    end
  end
end

if failures.empty?
  puts 'bc2cpp call results mutation check: PASS'
else
  warn "bc2cpp call results mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
