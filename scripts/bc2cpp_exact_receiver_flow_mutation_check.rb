#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the exact-receiver levers of docs/adr/0301. Each mutant is a copy of tools/bc2cpp
# with one soundness condition broken; scripts/bc2cpp_exact_receiver_flow_check.rb, run against the
# mutant through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes
# means the condition has no negative case. An unmutated control runs first, in the same tree, and a mutant that only crashes is not a kill (Bc2cppMutationSupport).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_exact_receiver_flow_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_fixture_runtime'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['an instance-level freeze definition does not withdraw the freeze proof', 'codegen_return_classes.rb',
   "world.instance_native_dispatch_safe?('freeze')", 'true', /user freeze|overriding freeze/, true],
  ['a const_missing in the world does not withdraw the constant pools', 'codegen_class_pools.rb',
   "!installed.nil? && !installed.include?('const_missing') && ownerless_native_dispatch_safe?('const_missing')", 'true',
   /const_missing/, false],
  ['a constant the numeric proof poisons gets a pool', 'codegen_class_pools.rb',
   '@class_const_pools[name] = 0 unless group.structural', '@class_const_pools[name] = 0',
   /foreign Ruby definition|native definition|assigned a call result|computed const_set/, false],
  ['the registered-expression arm is taken for any exact class', 'codegen_native_send.rb',
   'exact = entries.find { |entry| entry[:owner][:class_name] == site[:klass] }', 'exact = entries.first',
   /every method answers what the interpreter answers/, true],
  ['the exact proof no longer reaches the POLY chain tail', 'codegen_send.rb',
   'poly = with_exact_core_site(exact_site) do', 'poly = with_exact_core_site(nil) do', /ErHolder#lit_join|ErHolder#const_join/, false]
].freeze

# Concurrent mutants must not race to build the shared BC2CPP_FULL_BUILD_DIR: build it once first.
Bc2cppFixtureRuntime.full_or_build if ENV['BC2CPP_FULL_BUILD_DIR'] && MUTANTS.any?(&:last)

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected, needs_run|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected, needs_run: needs_run)
  end
) do |tree, mutant, run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb') }
  env['ERF_GENERATED_ONLY'] = '1' unless run_half
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_exact_receiver_flow_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp exact receiver flow mutation check: PASS'
else
  warn "bc2cpp exact receiver flow mutation check: #{failures.size} failure(s)"
  exit 1
end
