#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CLASS_POOLS / NILABLE_RECEIVER (docs/adr/0296). Each mutant is a copy of
# tools/bc2cpp with one soundness condition broken; scripts/bc2cpp_class_pools_check.rb, run against
# the mutant through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that
# passes means the condition has no negative case. An unmutated control runs first, in the same repository-layout
# tree, and must pass; a mutant that only crashes is not a kill (Bc2cppMutationSupport).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_class_pools_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_fixture_runtime'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['pools track structurally refused groups (writer, reflection, foreign source)', 'codegen_class_pools.rb',
   'unless group.structural', 'unless false', /read_written|read_refl|spells @box|define_method block/, false],
  ['an unassigned constructor path counts as assigned', 'codegen_class_pools.rb',
   "assured = owner.name != 'initialize' && numeric_ivar_assured?(owner.owner, name)", 'assured = true',
   /constructor path that leaves @lz unassigned/, false],
  ['a store the flow cannot name joins the pool as nothing', 'codegen_class_pools.rb',
   'if mask.nil? || mask.anybits?(CLASS_POOL_UNSHIPPABLE)', 'mask &= ~CLASS_POOL_UNSHIPPABLE if mask; if mask.nil?',
   /read_param|pl_use_param|read_mixed/, false],
  ['a pool site of another class is not joined', 'codegen_class_pools.rb',
   'joined |= mask', 'joined |= mask if joined.zero?', /read_mixed|pl_use_two/, false],
  ['a nil is assumed away everywhere, not only on the tested arm', 'codegen_return_classes.rb',
   '@nonnil_receiver == [irep.label, idx, reg] ? mask & ~NumericFlow::NIL : mask', 'mask & ~NumericFlow::NIL',
   /every method answers what the interpreter answers|nil local/, true],
  ['nil is always unanswerable (to_s on nil raises instead of answering)', 'codegen_class_pools.rb',
   'def nil_unanswerable?(name)', "def nil_unanswerable?(name)\n    return true",
   /pl_nil_ok|every method answers what the interpreter answers/, true],
  ['the nil arm is dropped', 'codegen_nilable_receiver.rb',
   '"  if (mrb_nil_p(#{recv})) {\n"', '"  if (0 && mrb_nil_p(#{recv})) {\n"',
   /nil receiver raises|every method answers what the interpreter answers|nil local/, true]
].freeze

# Concurrent mutants must not race to build the shared BC2CPP_FULL_BUILD_DIR: build it once first.
Bc2cppFixtureRuntime.full_or_build if ENV['BC2CPP_FULL_BUILD_DIR'] && MUTANTS.any?(&:last)

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected, needs_run|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected, needs_run: needs_run)
  end
) do |tree, mutant, run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb') }
  env['PL_GENERATED_ONLY'] = '1' unless run_half
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_class_pools_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp class pools mutation check: PASS'
else
  warn "bc2cpp class pools mutation check: #{failures.size} failure(s)"
  exit 1
end
