#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for FROZEN_TABLES (docs/adr/0306). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp_frozen_tables_check.rb, run against the mutant through
# BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards the condition.
#
# The mutants run through Bc2cppMutantPool, so BC2CPP_JOBS (default: the core count, at most 4) of
# them go at a time and a mutant stops at the FAIL line it is expected to cause. Each generated-code
# half generates one world per soundness condition, so a mutant that is already caught needs no more
# of them (docs/ci.md, "Mutant pool").
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_frozen_tables_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'bc2cpp_mutant_pool'

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

failures = []
# A :site_gone marker (naming the files that lost the pattern) when the mutation site is gone, else
# the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected, also)|
  # Inside the repo so the copy's own ../.. is the repo root: the closed world reads the build's sources from there.
  Dir.mktmpdir('.ftmut', ROOT) do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    # `also`: more [file, pattern, replacement] edits of the same mutant (a condition two gates enforce).
    edits = [[file, pattern, replacement]] + Array(also)
    gone = edits.reject do |edit_file, edit_pattern, edit_replacement|
      path = File.join(dir, 'bc2cpp', edit_file)
      text = File.read(path)
      text.include?(edit_pattern) && File.write(path, text.sub(edit_pattern) { edit_replacement })
    end
    next [:site_gone, gone.map(&:first)] unless gone.empty?

    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'FT_GENERATED_ONLY' => '1' }
    # A mutant stops at the FAIL line it is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_frozen_tables_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, _file, _pattern, _replacement, expected, _also), run|
  if run.is_a?(Array) && run.first == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{run.last.join(', ')}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp frozen tables mutation check: PASS'
else
  warn "bc2cpp frozen tables mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
