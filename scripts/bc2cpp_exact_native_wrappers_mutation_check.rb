#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for EXACT_NATIVE_WRAPPER (docs/adr/0307). Each mutant is a copy of tools/bc2cpp with one
# condition broken; scripts/bc2cpp_exact_native_wrappers_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition
# has no negative case.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_exact_native_wrappers_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_fixture_runtime'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['a nil receiver is taken as exact without the nil test', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)',
   'klass = return_class_of_mask(exact_flow_mask(irep, idx, reg)&.then { |m| m & ~NumericFlow::NIL })',
   /nil-or-Bitmap takes one nil test|raises where the interpreter does|every method answers/, false],
  ['an argument receiver counts as exact (the hint, not the flow)', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)', "klass = 'RGSS::Bitmap'",
   /argument receiver keeps the class test|keeps the guard/, false],
  ['blt reports the opacity as given when it is not', 'codegen_exact_native_wrappers.rb',
   "argv.size == 5 ? 'TRUE' : 'FALSE'", "'TRUE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_blt_direct\)/, false],
  ['stretch_blt reports the opacity as not given when it is', 'codegen_exact_native_wrappers.rb',
   "argv.size == 4 ? 'TRUE' : 'FALSE'", "'FALSE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_stretch_blt_direct\)/, false],
  ['draw_text packs one argument too many', 'codegen_exact_native_wrappers.rb',
   'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size},', 'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size + 1},',
   /the unguarded call is the guarded arm's call \(rgss::bitmap_draw_text_direct\)/, false],
  ['any arity is taken (a fill_rect of two arguments gets the five-argument body)', 'codegen_exact_native_wrappers.rb',
   'return [:call, builder] if arities.include?(argc)', 'return [:call, builder]',
   /bad_arity: a call of another arity/, false],
  ['the kill switch is ignored', 'codegen_exact_native_wrappers.rb',
   "ENV.fetch('BC2CPP_EXACT_NATIVE_WRAPPERS', '1') != '0'", 'true', /the kill switch/, false],
  ['the nil test is not worth it for an unguarded call (EXACT_NATIVE_WRAPPER leaves NILABLE_RECEIVER\'s exact marks)',
   'codegen_nilable_receiver.rb', 'NATIVE_EXACT_DIRECT|EXACT_NATIVE_WRAPPER|', 'NATIVE_EXACT_DIRECT|', /NILABLE_RECEIVER's exact marks name the unguarded wrapper call/, false]
].freeze

# Concurrent mutants must not race to build the shared BC2CPP_FULL_BUILD_DIR: build it once first.
Bc2cppFixtureRuntime.full_or_build if ENV['BC2CPP_FULL_BUILD_DIR'] && MUTANTS.any?(&:last)

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected, needs_run|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected, needs_run: needs_run)
  end
) do |tree, mutant, run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb') }
  env['EW_GENERATED_ONLY'] = '1' unless run_half
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_exact_native_wrappers_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp exact native wrappers mutation check: PASS'
else
  warn "bc2cpp exact native wrappers mutation check: #{failures.size} failure(s)"
  exit 1
end
