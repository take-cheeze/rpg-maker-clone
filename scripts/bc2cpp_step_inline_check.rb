#!/usr/bin/env ruby
# frozen_string_literal: true

# Check STEP_LOOP_SUPPORT (docs/adr/0273): `a.step(limit, step) { }`, `a.upto(limit) { }` and
# `a.downto(limit) { }` with operands that are provably Integers compile to a native loop in
# the method's own frame instead of a block call.
#
#   - generated code: which sites are inlined, and that a Float receiver or limit, a zero
#     step and a step that is not a literal keep the call;
#   - behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the
#     compiled methods return what the interpreted ones do (values, break, next, an empty
#     range, negative steps, parameterless blocks, captured locals, Float and Range users).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_step_inline_check.rb

require 'tmpdir'
require_relative 'bc2cpp_fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class StFx
    def step_sum; s = 0; 1.step(10, 3) { |i| s += i }; s; end
    def step_value; 1.step(10, 3) { |i| i * 100 }; end
    def step_neg; a = []; 10.step(1, -4) { |i| a << i }; a; end
    def step_empty; a = []; 5.step(1, 1) { |i| a << i }; a; end
    def step_empty_neg; a = []; 1.step(5, -1) { |i| a << i }; a; end
    def step_one; a = []; 4.step(4, 7) { |i| a << i }; a; end
    def step_noparam; n = 0; 0.step(9, 3) { n += 1 }; n; end
    def step_break; 1.step(100, 1) { |i| break i * 2 if i > 4 }; end
    def step_break_none; 1.step(3, 1) { |i| break :never if i > 9 }; end
    def step_next; a = []; 1.step(7, 1) { |i| next if i.odd?; a << i }; a; end
    def step_param_write; a = []; 1.step(3, 1) { |i| i += 10; a << i }; a; end
    def step_upvar; t = 0; last = nil; 2.step(8, 2) { |i| t += i; last = i }; [t, last]; end
    def step_ivar; @acc = []; 0.step(6, 3) { |i| @acc << i }; @acc; end
    def step_nested_block; a = []; 1.step(2, 1) { |i| [10, 20].each { |k| a << i + k } }; a; end
    def step_nested_step; a = []; 1.step(2, 1) { |i| 1.step(2, 1) { |j| a << i * j } }; a; end
    def step_big; a = []; 1073741820.step(1073741823, 1) { |i| a << i }; a; end
    def step_return; 1.step(9, 1) { |i| return i if i == 4 }; :none; end
    def step_raise; 1.step(9, 1) { |i| raise ArgumentError, "at #{i}" if i == 3 }; end
    def upto_sum; s = 0; 3.upto(6) { |i| s += i }; s; end
    def upto_empty; a = []; 6.upto(3) { |i| a << i }; a; end
    def upto_value; 3.upto(5) { |i| i }; end
    def upto_dynamic; n = 5; a = []; n.upto(n + 2) { |i| a << i }; a; end
    def downto_list; a = []; 6.downto(3) { |i| a << i }; a; end
    def downto_empty; a = []; 3.downto(6) { |i| a << i }; a; end
    def downto_dynamic; n = 5; a = []; (n * 2).downto(n + 2) { |i| a << i }; a; end
    # Not provably Integer, or not a loop this pass may take: the call stays.
    def float_recv; a = []; 1.0.step(2.0, 0.5) { |x| a << x }; a; end
    def float_limit; a = []; 1.step(2.5, 1) { |x| a << x }; a; end
    def float_step; a = []; 1.step(2, 0.5) { |x| a << x }; a; end
    def float_upto; a = []; 1.upto(3.5) { |x| a << x }; a; end
    def unknown_limit(n); a = []; 1.step(n, 2) { |x| a << x }; a; end
    def unknown_step(k); a = []; 1.step(9, k) { |x| a << x }; a; end
    def zero_step; 0.step(5, 0) { |x| x }; end
    def no_block; 1.step(7, 3).to_a; end
    def range_step; a = []; (1..7).step(3) { |x| a << x }; a; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = StFx.new
  %i[step_sum step_value step_neg step_empty step_empty_neg step_one step_noparam step_break step_break_none
     step_next step_param_write step_upvar step_ivar step_nested_block step_nested_step step_big step_return
     step_raise upto_sum upto_empty upto_value upto_dynamic downto_list downto_empty downto_dynamic
     float_recv float_limit float_step float_upto zero_step no_block range_step].each do |name|
    out = begin
      fx.send(name).inspect
    rescue => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  [[3], [0], [9], [-2]].each { |args| puts "unknown_limit#{args}: #{(fx.unknown_limit(*args) rescue $!.class).inspect}" }
  [[2], [-2], [0], [1.5]].each { |args| puts "unknown_step#{args}: #{(fx.unknown_step(*args) rescue $!.class).inspect}" }
  puts 'end'
RUBY

INLINED = %w[step_sum step_value step_neg step_empty step_empty_neg step_one step_noparam step_break step_break_none
             step_next step_param_write step_upvar step_ivar step_nested_block step_nested_step step_big step_return
             step_raise upto_sum upto_empty upto_value downto_list downto_empty].freeze
# upto_dynamic / downto_dynamic take a limit computed by arithmetic (`n + 2`). Since ADR 0279 an
# arithmetic result is no longer a proven Fixnum (it can overflow into a bignum), so the loop keeps
# its call; the driver above still compares their results with the interpreter.
KEPT_ARITHMETIC_LIMIT = %w[upto_dynamic downto_dynamic].freeze
KEPT = %w[float_recv float_limit float_step float_upto unknown_limit unknown_step zero_step no_block range_step].freeze

def body_of(code, fn)
  code[/^mrb_value StFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

Dir.mktmpdir do |dir|
  code, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
  INLINED.each do |fn|
    body = body_of(code, fn)
    check.call("#{fn}: the loop is inlined", body.include?('bc2cpp_step_i_') && !body.include?('#error'))
  end
  KEPT_ARITHMETIC_LIMIT.each do |fn|
    check.call("#{fn}: an arithmetic limit is not a proven Fixnum, so the call is kept", !body_of(code, fn).include?('bc2cpp_step_i_'))
  end
  KEPT.each do |fn|
    check.call("#{fn}: the call is kept", !body_of(code, fn).include?('bc2cpp_step_i_'))
  end
  check.call('a literal limit is a constant of the loop', body_of(code, 'step_sum').include?('const long long bc2cpp_step_limit_'))
  check.call('the counter cannot wrap a 32-bit mrb_int (a long long)', body_of(code, 'step_big').include?('for (long long bc2cpp_step_i_'))
  check.call('no compiled method needed a resumable frame', !code.include?('RESUMABLE_'))
  check.call('the diagnostics list the inlined methods as compiled',
             INLINED.all? { |fn| err.include?("StFx_#{fn} / StFx_#{fn}_impl") })
end

full = Bc2cppFixtureRuntime.full_or_build
if full.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  Dir.mktmpdir do |dir|
    code, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"BCD(#{DRIVER})BCD";
        mrb_load_string(M, src);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[StFx], body, build: full, full: true)
    check.call('the fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs", interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" } if interpreted && compiled
    puts output.lines.last(20).join unless built
  end
end

if failures.empty?
  puts 'bc2cpp step inline check: PASS'
else
  warn "bc2cpp step inline check: #{failures.size} failure(s)"
  exit 1
end
