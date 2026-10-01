#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for FROZEN_TABLES (docs/adr/0306). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp_frozen_tables_check.rb, run against the mutant through
# BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards the condition.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_frozen_tables_mutation_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, label of a check that must FAIL]
MUTANTS = [
  ['a literal frozen later (not back to back) still counts', 'codegen_frozen_tables.rb',
   'return nil unless at + 1 == idx && lit.reg == insn.reg', '', /late_freeze/],
  ['an out-of-range literal index reads the last slot instead of nil', 'frozen_tables.rb',
   'return NumericFlow::NIL unless index.between?(-n, n - 1)', 'return shape.slots.last || NumericFlow::NIL unless index.between?(-n, n - 1)',
   /oob_plain/],
  ['a missing Hash key reads no value (the nil default is forgotten)', 'frozen_tables.rb',
   'pos ? shape.slots[pos] : NumericFlow::NIL', 'pos ? shape.slots[pos] : 0', /hash_absent_plain/],
  ['a non-Integer index is trusted (a Range reads an Array)', 'frozen_tables.rb',
   'return NumericFlow::OTHER unless key_int', 'return shape.joined unless key_int', /may be a Range/],
  ['a redefined Array#[] is ignored', 'codegen_frozen_tables.rb',
   "return :no_core_native unless builtin_class_send_safe?(name, [klass])", '', /module prepended/],
  ['a Ruby definition on the receiver chain is ignored', 'codegen_frozen_tables.rb',
   'return :ruby_definition if', 'return nil if false &&', /Kernel#freeze redefined|Object#freeze redefined|Array#freeze redefined/],
  ['an outside native registration is ignored', 'codegen_frozen_tables.rb',
   ':native_on_ancestor if named.any? { |owner| owners.include?(owner) }', 'nil', /native source registering/],
  ['a foreign Ruby definition is ignored', 'codegen_frozen_tables.rb',
   'return :foreign_ruby if owners.any? { |owner| ForeignDefiners.defines?(frozen_table_foreign_paths, owner, name) }', '',
   /foreign Ruby source defining Array#\[\]/],
  ['a singleton maker is ignored', 'codegen_frozen_tables.rb',
   "return 'instances may gain singleton methods' unless cw.exact_instances_singleton_free?", '', /singleton method on an Array|extend on an object/],
  ['the exact receiver accepts a mix with non-table classes', 'codegen_frozen_tables.rb',
   'return nil unless mask.is_a?(Integer) && mask.positive? && (mask & ~@frozen_tables.mask).zero?',
   'return nil unless mask.is_a?(Integer) && mask.positive? && mask.anybits?(@frozen_tables.mask)', /mutable Array became an exact/],
  ['the kill switch is ignored', 'codegen_frozen_tables.rb',
   "return 'disabled by BC2CPP_FROZEN_TABLES=0' if ENV['BC2CPP_FROZEN_TABLES'] == '0'", '', /kill switch/]
].freeze

failures = []
MUTANTS.each do |name, file, pattern, replacement, expected|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'FT_GENERATED_ONLY' => '1' }
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_frozen_tables_check.rb'))
    failed = out.lines.grep(/^\s+FAIL /)
    killed = !status.success? && failed.any? { |l| l.match?(expected) }
    puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
    unless killed
      puts failed.first(5).join
      failures << name
    end
  end
end

if failures.empty?
  puts 'bc2cpp frozen tables mutation check: PASS'
else
  warn "bc2cpp frozen tables mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
