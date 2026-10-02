#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CAPTURED_LOCAL_CLASS (docs/adr/0308). Each mutant is a copy of tools/bc2cpp with one soundness
# condition broken; scripts/bc2cpp_captured_local_class_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL
# on the check that guards that condition. A mutant that passes means the condition has no negative case.
#
# One guard has no killing world and so no mutant: the explicit nested-write test (the flow already reads such a
# register as OTHER, so it stays as defence in depth, as numeric_upvar_mask keeps it).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_captured_local_class_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['writes after the closure was created are not joined', 'codegen_captured_locals.rb',
   'state[index] | (@rc_writes.dig(ancestor.label, index) || 0)', 'state[index]',
   /NEG CaHolder#cap_lambda_late|every method answers what the interpreter answers/, true],
  ['the defining frame is one block too shallow', 'codegen_captured_locals.rb',
   '(level + 1).times do', 'level.times do',
   /cap_nested|cap_hash|cap_two_blocks/, false],
  ['an argument of the defining frame is taken as its literal', 'codegen_captured_locals.rb',
   'return NumericFlow::OTHER unless state', 'return NumericFlow::OTHER unless state; state = state.map { |m| m.zero? ? m : NumericFlow::HSH }',
   /NEG CaHolder#cap_arg|NEG CaHolder#cap_mixed|NEG CaHolder#cap_unknown_call/, false],
  ['the kill switch is ignored', 'codegen_captured_locals.rb',
   "ENV.fetch('BC2CPP_CAPTURED_LOCAL_CLASS', '1') != '0' && captured_local_writers_absent?", 'captured_local_writers_absent?',
   /kill switch \(BC2CPP_CAPTURED_LOCAL_CLASS=0\)/, false],
  ['a binding, eval or local_variable_set never withdraws the proof', 'codegen_captured_locals.rb',
   'return false if names.include?(sym)', 'return false if false',
   /NEG a binding|NEG a local_variable_set|NEG an eval|NEG a binding named by a symbol/, false],
  ['a string class_eval never withdraws the proof', 'codegen_captured_locals.rb',
   '&& !literal_block_argument?(irep, idx, insn)', '&& false',
   /NEG a string class_eval/, false],
  ['a native of the build that writes locals by name is ignored', 'codegen_captured_locals.rb',
   'return false if names.any? { |name| !@closed_world.native_paths_spelling(name).empty? || @closed_world.outside_ruby_token?(name) }',
   'return false if false',
   /NEG a build gem with a native|NEG a build gem whose mrblib/, false],
  ['an outside Ruby source that spells binding is ignored', 'codegen_captured_locals.rb',
   '|| @closed_world.outside_ruby_token?(name)', '',
   /NEG a build gem whose mrblib spells binding/, false]
].freeze

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected, needs_run|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected, needs_run: needs_run)
  end
) do |tree, mutant, run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb') }
  env['CAL_GENERATED_ONLY'] = '1' unless run_half
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_captured_local_class_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp captured local class mutation check: PASS'
else
  warn "bc2cpp captured local class mutation check: #{failures.size} failure(s)"
  exit 1
end
