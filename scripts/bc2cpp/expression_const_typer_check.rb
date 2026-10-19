#!/usr/bin/env ruby
# frozen_string_literal: true

# EXPRESSION_CONST (docs/bc2cpp-type-check.md, "Constant typer"): with BC2CPP_EXPRESSION_CONST_TYPER=1 the constant rows
# take the type of the class flow over the assignment's own IREP (TypeFacts#expression_site_type). Each fixture is one
# program analysed as the whole closed world (TypeCheckRun, --files semantics); the rows are read from its facts file.
# Positive cases must type the constant with the flow's class set; negative cases must leave it untyped.
# Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/expression_const_typer_check.rb

require 'json'
require 'tmpdir'
require_relative '../../tools/bc2cpp/type_check_run'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP expression_const_typer_check: MRBC is not set to a host mrbc'
  exit 0
end

ROOT = File.expand_path('../..', __dir__)
TOOLS = File.join(ROOT, 'tools/bc2cpp')
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The constant rows of one program, keyed by qualified name, with the typer on.
rows_of = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    work = File.join(dir, 'out')
    FileUtils.mkdir_p(work)
    TypeCheckRun.run(root: ROOT, mrbc: ENV.fetch('MRBC'), workdir: work, sources: [rb], sends: false,
                     extra_env: { 'BC2CPP_EXPRESSION_CONST_TYPER' => '1' }, display_root: dir, tools_dir: TOOLS)
    JSON.parse(File.read(File.join(work, 'facts.json')))['constants'].to_h { |r| [r['name'], r] }
  end
end

puts '== positive: the flow types the initializer'
rows = rows_of.call(<<~RUBY)
  LIMIT = 2 + 3 * 4
  FLAGS = 1 | 4
  NAMES = ['a', 'b'].freeze
  OPTS = { a: 1 }.merge({ b: 2 })
  class Palette
    RED = Color.new(255, 0, 0, 255)
  end
RUBY
check.call('a literal integer expression is Integer (LIMIT)', rows.dig('LIMIT', 'type') == 'Integer')
check.call('a bit-or of literals is Integer (FLAGS)', rows.dig('FLAGS', 'type') == 'Integer')
check.call('a frozen literal Array is Array (NAMES)', rows.dig('NAMES', 'type') == 'Array')
check.call('a Hash merge is Hash (OPTS)', rows.dig('OPTS', 'type') == 'Hash')
check.call('Color.new in a class body is Color (Palette::RED)', rows.dig('Palette::RED', 'type') == 'Color' ||
                                                              rows.dig('Palette::RED', 'type') == 'RGSS::Color')
check.call('the source is inferred:expression', rows.dig('LIMIT', 'source') == 'inferred:expression')

puts '== negative: the flow refuses'
redefined = rows_of.call(<<~RUBY)
  class Hash
    def merge(other)
      1
    end
  end
  OPTS = { a: 1 }.merge({ b: 2 })
RUBY
check.call('a redefined Hash#merge leaves OPTS untyped', redefined.dig('OPTS', 'type').nil?)

non_literal = rows_of.call(<<~RUBY)
  X = 1 + $global
RUBY
check.call('a non-literal operand leaves X untyped', non_literal.dig('X', 'type').nil?)

twice = rows_of.call(<<~RUBY)
  X = 1
  X = 'text'
RUBY
check.call('a constant assigned twice with different classes stays untyped', twice.dig('X', 'type').nil?)

if failures.empty?
  puts 'expression_const_typer_check: ok'
  exit 0
end
puts "expression_const_typer_check: #{failures.size} failure(s)"
exit 1
