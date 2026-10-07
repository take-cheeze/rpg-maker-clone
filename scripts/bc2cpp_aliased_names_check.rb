#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CodeGen#numeric_aliased_names (docs/adr/0370): the names a body is given by `alias`, `alias_method` and
# `define_method`. An irep whose aliasing operands are all Symbol literals contributes exactly those names, so an
# `attr_reader` next to an unrelated `alias_method` keeps its return facts; an operand that is not a literal keeps
# the old rule for that irep (every Symbol it loads).
#
# Usage: ruby scripts/bc2cpp_aliased_names_check.rb   (needs a host mrbc: MRBC=path)

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class AlLiteral
    attr_reader :al_keep, :al_other
    def al_orig; 1; end
    alias al_kw al_orig
    alias_method :al_meth, :al_orig
    define_method(:al_def) { 2 }
  end

  class AlComputed
    attr_reader :ac_keep
    def ac_orig; 1; end
    alias_method "ac_\#{1}".to_sym, :ac_orig
  end

  class AlNone
    attr_reader :an_keep
  end
RUBY

unless ENV['MRBC']
  puts '-- SKIP: set MRBC'
  exit 0
end

ireps, = Dir.mktmpdir do |dir|
  path = File.join(dir, 'aliased.rb')
  File.write(path, SOURCE)
  parsed, root_label = compile_ireps(path, 'bc2cpp_aliased', dir)
  [parsed, build_registry(parsed, root_label)[0]]
end
names = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new).numeric_aliased_names

check.call('the names an alias, alias_method and define_method spell are aliased',
           %w[al_kw al_orig al_meth al_def].all? { |n| names.include?(n) })
check.call('an attr_reader in the same class body is not', !names.include?('al_keep') && !names.include?('al_other'))
check.call('NEG a computed alias_method keeps the old rule for its irep: every Symbol the irep loads',
           names.include?('ac_orig') && names.include?('ac_keep'))
check.call('a class body with no aliasing operation contributes nothing', !names.include?('an_keep'))

if failures.empty?
  puts 'bc2cpp aliased names check: PASS'
else
  warn "bc2cpp aliased names check: #{failures.size} failure(s)"
  exit 1
end
