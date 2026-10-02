#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for ACCESSOR_RETURN_CLASS and EXACT_CORE_ARMS (docs/adr/0309). Each mutant is a copy of
# tools/bc2cpp with one soundness condition broken; scripts/bc2cpp_call_results_check.rb, run against the
# mutant through BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards that
# condition. A mutant that passes means the condition has no negative case. An unmutated control runs first, in the
# same repository-layout tree, and must pass; a mutant that only crashes is not a kill (Bc2cppMutationSupport).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_call_results_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_mutation_support'

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

# CR_MUTANT=text runs the mutants whose name contains it (while developing a new one).
mutants = ENV['CR_MUTANT'] ? MUTANTS.select { |m| m.first.include?(ENV['CR_MUTANT']) } : MUTANTS
failures = Bc2cppMutationSupport.run_harness(
  mutants.map do |name, file, pattern, replacement, expected|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected)
  end
) do |tree, mutant, _run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb'), 'CR_GENERATED_ONLY' => '1' }
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_call_results_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp call results mutation check: PASS'
else
  warn "bc2cpp call results mutation check: #{failures.size} failure(s)"
  exit 1
end
