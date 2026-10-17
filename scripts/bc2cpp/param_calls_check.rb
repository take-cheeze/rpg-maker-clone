#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks TypeCheckRbs.param_calls and the interface lines on a small fixture: a parameter with no type gets the
# methods sent to it (identifier names only, sorted, unique), a typed parameter and a send to another argument
# are left out, and each fact is written as an RBS interface that parses.
#
#   ruby scripts/bc2cpp/param_calls_check.rb

require 'rbs'
require_relative '../../tools/bc2cpp/type_check_rbs'

facts = {
  'methods' => [
    { 'owner' => 'Game::Map', 'name' => 'tile', 'scope' => 'engine',
      'params' => [{ 'name' => 'x', 'type' => nil }, { 'name' => 'y', 'type' => 'Integer' }, { 'name' => 'z', 'type' => nil }] }
  ]
}
rows = [
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg1', 'name' => 'to_i' },
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg1', 'name' => 'to_i' },
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg1', 'name' => 'empty?' },
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg1', 'name' => '+' },
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg2', 'name' => 'to_s' },
  { 'source' => 'argument', 'owner' => 'Game::Map#tile', 'detail' => 'arg3', 'name' => 'size' },
  { 'source' => 'ivar', 'owner' => 'Game::Map#tile', 'detail' => '@a', 'name' => 'size' }
]

failures = []
check = ->(name, ok) { failures << name unless ok }

calls = TypeCheckRbs.param_calls(rows, facts)
check.call('only the untyped parameters with sends get a fact', calls.map { |c| [c['index'], c['calls']] } == [[1, %w[empty? to_i]], [3, %w[size]]])
check.call('a typed parameter is left out', calls.none? { |c| c['index'] == 2 })
check.call('operator names are left out', calls.first['calls'].none? { |m| m == '+' })
check.call('a non-argument receiver is left out', calls.none? { |c| c['calls'].include?('size') && c['index'] == 1 })

facts['param_calls'] = calls
lines = TypeCheckRbs.interface_lines(facts)
check.call('one interface per fact', lines.size == calls.size)
check.call('the interface names its methods untyped', lines.first.include?('def to_i: (*untyped) -> untyped'))
check.call('the interface file parses as RBS', begin
  RBS::Parser.parse_signature(lines.join("\n"))
  true
rescue RBS::ParsingError
  false
end)

if failures.empty?
  puts 'param calls check: PASS'
else
  puts "param calls check: FAIL #{failures.join('; ')}"
  exit 1
end
