#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for FROZEN_TABLES (docs/adr/0306). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp_frozen_tables_check.rb, run against the mutant through
# BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards the condition. An unmutated control runs
# first, in the same repository-layout tree, and must pass; a mutant that only crashes is not a kill
# (Bc2cppMutationSupport).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_frozen_tables_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, label of a check that must FAIL]
MUTANTS = [
  ['an out-of-range literal index reads the last slot instead of nil', 'frozen_tables.rb',
   'return NumericFlow::NIL unless index.between?(-n, n - 1)', 'return shape.slots.last || NumericFlow::NIL unless index.between?(-n, n - 1)',
   /oob_plain/],
  ['a missing Hash key reads no value (the nil default is forgotten)', 'frozen_tables.rb',
   'pos ? shape.slots[pos] : NumericFlow::NIL', 'pos ? shape.slots[pos] : shape.joined', /hash_absent_plain/],
  ['a non-Integer index is trusted (a Range reads an Array)', 'frozen_tables.rb',
   'return NumericFlow::OTHER unless key_int', 'return shape.joined unless key_int', /may be a Range/],
  ['a redefined Array#[] is ignored', 'codegen_frozen_tables.rb',
   "return :no_core_native unless builtin_class_send_safe?(name, [klass])", '', /module prepended/],
  ['a Ruby definition on the receiver chain is ignored', 'codegen_frozen_tables.rb',
   'return :ruby_definition if', 'return nil if false &&', /Kernel#freeze redefined|Object#freeze redefined/,
   [['codegen_frozen_tables.rb', "return 'freeze is not only Kernel#freeze' unless kernel_freeze_only?", '']]],
  ['an outside native registration is ignored', 'codegen_frozen_tables.rb',
   ':native_on_ancestor if named.any? { |owner| owners.include?(owner) }', 'nil', /native source registering/],
  ['a foreign Ruby definition is ignored', 'codegen_frozen_tables.rb',
   'return :foreign_ruby if owners.any? { |owner| ForeignDefiners.defines?(frozen_table_foreign_paths, owner, name) }', '',
   /foreign Ruby source defining Array#\[\]/],
  ['a singleton maker is ignored', 'codegen_frozen_tables.rb',
   "return 'instances may gain singleton methods' unless cw.exact_instances_singleton_free?", '', /singleton method on an Array|extend on an object/,
   [['codegen_class_pools.rb', 'return false unless @closed_world&.exact_instances_singleton_free? && @foreign_method_names', 'return false unless @foreign_method_names']]],
  ['the kill switch is ignored', 'codegen_frozen_tables.rb',
   "return 'disabled by BC2CPP_FROZEN_TABLES=0' if ENV['BC2CPP_FROZEN_TABLES'] == '0'", '', /kill switch/]
].freeze

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected, also|
    # `also`: more [file, pattern, replacement] edits of the same mutant (a condition two gates enforce).
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]] + Array(also), expected: expected)
  end
) do |tree, mutant, _run_half|
  env = { 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb'), 'FT_GENERATED_ONLY' => '1' }
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_frozen_tables_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp frozen tables mutation check: PASS'
else
  warn "bc2cpp frozen tables mutation check: #{failures.size} failure(s)"
  exit 1
end
