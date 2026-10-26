#!/usr/bin/env ruby
# frozen_string_literal: true

# LOOP_INLINE (tools/bc2cpp/codegen_loop_regions.rb, codegen_loop_inline.rb): `loop do ... end` with a
# parameterless block becomes a native `for (;;)`, its `break` a jump instead of a thrown bc2cpp_block_break.
#
#   1. placement: each POSITIVE_INLINED method has the loop and neither a Kernel#loop call nor a thrown break; a
#      block parameter, a program that sends Enumerator#next or raises StopIteration and a class with its own `loop`
#      keep the call (so do a
#      loop nested in an inlined body, which the nested pass refuses for its BREAK, and a body with an `ensure`, as
#      for every inlined block); BC2CPP_LOOP_INLINE=0 inlines none.
#   2. parity, interpreted against compiled: break values, `next`, a return from the block, a raise, nested loops
#      and an `ensure` inside the body print the same on both sides and the value written here. The
#      Enumerator#next fixture is placement only: its compiled run raises a guard violation with or without this
#      pass (the engine sends no #next).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/loop_inline_check.rb
# Without a full-core build (fixture_runtime.rb) the runtime half prints SKIP.

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

POSITIVE = <<~RUBY
  class LoopPos
    def ber(bytes)
      ret = 0
      i = 0
      loop do
        b = bytes[i]
        raise 'truncated' if b.nil?
        i += 1
        ret = (ret << 7) | (b & 0x7f)
        break if (b & 0x80) == 0
      end
      ret
    end

    def first_big(list)
      i = 0
      found = loop do
        v = list[i]
        i += 1
        next if v < 10
        break v
      end
      [found, i]
    end

    def returned(list)
      i = 0
      loop do
        return list[i] * 2 if list[i] > 5
        i += 1
      end
    end

    def nested(n)
      out = 0
      i = 0
      loop do
        j = 0
        loop do
          break if j >= i
          out += j
          j += 1
        end
        i += 1
        break if i > n
      end
      out
    end

    def with_ensure(n)
      log = []
      i = 0
      loop do
        begin
          i += 1
          log << i
        ensure
          log << -i
        end
        break if i >= n
      end
      log
    end

    def bare_break
      loop { break }
    end
  end
RUBY

POSITIVE_EXPECTED = {
  'LoopPos.new.ber([0x81, 0x01])' => '129',
  'LoopPos.new.ber([0x05])' => '5',
  "begin; LoopPos.new.ber([0x81]); rescue RuntimeError => e; e.message; end" => '"truncated"',
  'LoopPos.new.first_big([1, 2, 30, 4])' => '[30, 3]',
  'LoopPos.new.returned([1, 9, 2])' => '18',
  'LoopPos.new.nested(3)' => '4',
  'LoopPos.new.with_ensure(2)' => '[1, -1, 2, -2]',
  'LoopPos.new.bare_break' => 'nil',
}.freeze
POSITIVE_INLINED = %w[ber first_big returned bare_break].freeze

# A block parameter (Kernel#loop yields nothing, so the parameter is nil, but the shape is not modelled).
PARAM = <<~RUBY
  class LoopParam
    def counted
      n = 0
      loop do |x|
        n += 1
        break [x, n] if n > 2
      end
    end
  end
RUBY
PARAM_EXPECTED = { 'LoopParam.new.counted' => '[nil, 3]' }.freeze

# A program that sends Enumerator#next may raise StopIteration into a loop body, which Kernel#loop rescues.
STOPS = <<~RUBY
  class LoopStops
    def drained(list)
      e = list.each
      out = []
      loop do
        out << e.next
      end
      out
    end
  end
RUBY

# A program that raises StopIteration itself ends a loop with its result.
RAISES = <<~RUBY
  class LoopRaises
    def stopped(n)
      i = 0
      v = loop do
        i += 1
        raise StopIteration if i == n
      end
      [v, i]
    end
  end
RUBY
RAISES_EXPECTED = { 'LoopRaises.new.stopped(3)' => '[nil, 3]' }.freeze

# A program-defined `loop` is not Kernel#loop.
OWN = <<~RUBY
  class LoopOwn
    def loop
      yield
      :own
    end

    def run
      n = 0
      r = loop do
        n += 1
      end
      [r, n]
    end
  end
RUBY
OWN_EXPECTED = { 'LoopOwn.new.run' => '[:own, 1]' }.freeze

# The method's own `_impl` body, without the block cfuncs emitted after it.
def method_chunk(code, owner, name)
  code[/^mrb_value #{owner}_#{name}_impl\(mrb_state\* M.*?(?=^(?:static |mrb_value |\/\/ \S+#\S+ \(compiled from)|\z)/m] || ''
end

def inlined?(chunk) = chunk.include?('for (;;)') && !chunk.include?('bc2cpp_break(M') && !chunk.include?('Kernel_loop')

harness_rows = lambda do |expected|
  <<~CPP
    static int scenario(mrb_state* M) {
      const char* rows[] = {
    #{expected.keys.map { |row| "    #{row.inspect}," }.join("\n")}
      };
      for (const char* src : rows) {
        mrb_value v = mrb_load_string(M, src);
        if (M->exc) { show_exc(M, src); continue; }
        show(M, src, v);
      }
      return 0;
    }
  CPP
end

fixtures = [
  ['positive', POSITIVE, %w[LoopPos], POSITIVE_EXPECTED],
  ['param', PARAM, %w[LoopParam], PARAM_EXPECTED],
  ['stops', STOPS, %w[LoopStops], nil],
  ['raises', RAISES, %w[LoopRaises], RAISES_EXPECTED],
  ['own', OWN, %w[LoopOwn], OWN_EXPECTED]
]

Dir.mktmpdir('loop-inline') do |dir|
  generated = fixtures.to_h do |label, source, owners, _|
    sub = File.join(dir, label)
    Dir.mkdir(sub)
    code, err = runtime.generate(source, sub, only_owners: owners)
    [label, [sub, code.to_s, err]]
  end

  pos = generated['positive'][1]
  check.call('positive fixture generates', !pos.empty?)
  POSITIVE_INLINED.each do |name|
    check.call("LoopPos##{name}: a native loop, no Kernel#loop call, no break catch", inlined?(method_chunk(pos, 'LoopPos', name)))
  end
  check.call('LoopParam#counted (a block parameter) keeps the call',
             !method_chunk(generated['param'][1], 'LoopParam', 'counted').include?('for (;;)'))
  check.call('LoopStops#drained (the program sends #next) keeps the call',
             !method_chunk(generated['stops'][1], 'LoopStops', 'drained').include?('for (;;)'))
  check.call('LoopRaises#stopped (the program raises StopIteration) keeps the call',
             !method_chunk(generated['raises'][1], 'LoopRaises', 'stopped').include?('for (;;)'))
  check.call('LoopOwn#run (a program-defined loop) keeps the call',
             !method_chunk(generated['own'][1], 'LoopOwn', 'run').include?('for (;;)'))

  saved = ENV.fetch('BC2CPP_LOOP_INLINE', nil)
  ENV['BC2CPP_LOOP_INLINE'] = '0'
  off = Dir.mktmpdir('loop-inline-off') { |d| runtime.generate(POSITIVE, d, only_owners: %w[LoopPos]).first.to_s }
  saved.nil? ? ENV.delete('BC2CPP_LOOP_INLINE') : ENV['BC2CPP_LOOP_INLINE'] = saved
  check.call('kill switch: BC2CPP_LOOP_INLINE=0 inlines no loop', !off.include?('for (;;)'))

  build = runtime.full_or_build
  if build
    fixtures.each do |label, _source, owners, expected|
      next unless expected

      sub, _code, err = generated[label]
      built, output = runtime.run(sub, err, owners, harness_rows.call(expected), build: build, full: true)
      sections = runtime.sections(output)
      check.call("#{label}: built and ran", built)
      check.call("#{label}: runtime parity, interpreted against compiled",
                 !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
      expected.each do |src, value|
        check.call("#{label}: #{src} => #{value}", sections['compiled'].to_a.include?("#{src} => #{value}"))
      end
      warn output unless failures.empty?
    end
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp loop inline check: PASS'
