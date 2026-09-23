#!/usr/bin/env ruby
# frozen_string_literal: true
# Self-test for scripts/rpg2k_closed_world_lint.rb: every cop fires on its
# construct, the look-alikes it must ignore stay quiet, and an allow comment
# needs a known cop and a reason.

require_relative 'rpg2k_closed_world_lint'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

lint = ->(src) { lint_file('fixture.rb', source: src) }
cops = ->(src) { lint.call(src)[0].map(&:cop) }

{
  'Dynamic/MethodMissing' => ["def method_missing(n, *a); end", "def respond_to_missing?(n, p = false); end"],
  'Dynamic/Send' => ['obj.send(name)', 'obj.public_send(field, 1)', 'obj.__send__(m)'],
  'Dynamic/ConstReflection' => ['Foo.const_get(sym)', 'Foo.const_set(:X, 1)', 'def self.const_missing(n); end'],
  'Dynamic/IvarReflection' => ['o.instance_variable_get(:@a)', 'o.instance_variable_set(:@a, 1)'],
  'Dynamic/MethodDefinition' => ['define_method(:x) { }', 'alias_method :a, :b', 'alias a b', 'undef x'],
  'Dynamic/Eval' => ['eval(src)', 'obj.instance_eval { }', 'Foo.class_eval { }', 'obj.method(:x)', 'binding'],
  'Dynamic/Extend' => ['obj.extend(Mod)'],
  'Dynamic/RescueModifier' => ['x = (a.b rescue nil)']
}.each do |cop, sources|
  sources.each { |src| check.call("#{cop} flags `#{src}`", cops.call(src).include?(cop)) }
end

[
  'obj.send(:fixed)', 'extend Mod', 'self.extend(Mod)', 'method = 1', 'x.method',
  "begin\n  a.b\nrescue StandardError\n  nil\nend"
].each { |src| check.call("`#{src.lines.first.strip}` is not flagged", cops.call(src).empty?) }

check.call('an allow comment with a reason suppresses the next line',
           cops.call("# rpg2k-lint:allow Dynamic/Send -- field names come from the LCF schema\no.send(f)").empty?)
check.call('a trailing allow comment suppresses its own line',
           cops.call('o.send(f) # rpg2k-lint:allow Dynamic/Send -- data-driven').empty?)
check.call('an allow comment only covers the cop it names',
           cops.call('o.send(f) # rpg2k-lint:allow Dynamic/Eval -- wrong cop') == ['Dynamic/Send'])
check.call('an allow comment without a reason is rejected',
           !lint.call('o.send(f) # rpg2k-lint:allow Dynamic/Send').last.empty?)
check.call('an allow comment naming an unknown cop is rejected',
           !lint.call('o.send(f) # rpg2k-lint:allow Dynamic/Nope -- x').last.empty?)

if failures.empty?
  puts 'rpg2k closed-world lint check: PASS'
else
  warn "rpg2k closed-world lint check: #{failures.size} failure(s)"
  exit 1
end
