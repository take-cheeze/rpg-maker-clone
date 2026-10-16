#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_RETURN_CHECK and DECLARED_CONSTANT_CHECK (docs/adr/0455): RBS return and constant declarations are checked,
# not seeded.
#
# 1. Positive cases: a declaration whose every return path proves is `checked, fact` and adds the fact the fixpoint
#    proofs produce -- FIXNUM_RETURN_PROOF (`RET`), ARRAY_RETURN_PROOF (`ARET`), the class return fixpoint (a guard-free
#    call on the result), INTEGER_CONSTANT_PROOF (`CONST`) and CONST_CONTAINER -- including where inference is silent
#    (a POLY Integer name, mutually recursive class returns, an Array#+ result, MUL/DIV constant expressions).
# 2. Negative cases, each a TC1010/TC1011 error at its Ruby file:line and a build abort: a nil path, a wrong-class
#    path, an unverifiable call, a reassigned constant, an aliased (runtime-defined) name; a POLY name declared on one
#    definition only is checked per definition and adds no fact; a POLY definition that does not hold is an error.
# 3. The type check (scripts/bc2cpp/type_check.rb --files --sig) reports the same diagnostics and exits 1.
# 4. With the declarations absent (BC2CPP_SIG_DIRS empty) nothing is checked and no fact is added.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/declared_return_check.rb

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (the host mrbc); the checks generate code'
  exit 0
end

ROOT = File.expand_path('../..', __dir__)

GOOD = <<~RUBY
  class DrBox
    def tag; :box; end
  end
  class DrOther
    def tag; :other; end
  end
  class DrCell
    def span_of; 3; end
  end
  class DrRow
    def span_of; 4; end
  end
  class DrFx
    def initialize(flag); @flag = flag; @extra = [2]; end
    def count_a; 3; end
    def count_b; @flag ? 4 : count_a; end
    def items; @flag ? [1] : []; end
    def more; (@extra || []) + items; end
    def make; DrBox.new; end
    def maybe_box; @flag ? DrBox.new : nil; end
    def ping(n); n == 0 ? DrBox.new : pong(n - 1); end
    def pong(n); ping(n); end
    def use_count; count_b + 1; end
    def use_items; items.map { |x| x + 1 }; end
    def use_ping; ping(2).tag; end
    def keep; @kept = pong(1); end
    def hinted; @flag ? 1 : nil; end
    def use_span(o); o.span_of + 1; end
    def use_cell; DrK::CELL + 1; end
  end
  module DrK
    W = 320
    CELL = W / 16
    AREA = CELL * 4
    TABLE = [1, 2, 3].freeze
    BOX = DrBox.new
  end
RUBY

GOOD_SIG = <<~RBS
  class DrCell
    def span_of: () -> Integer
  end
  class DrRow
    def span_of: () -> Integer
  end
  class DrFx
    def count_a: () -> Integer
    def count_b: () -> Integer
    def items: () -> Array[Integer]
    def more: () -> Array
    def make: () -> DrBox
    def maybe_box: () -> DrBox?
    def ping: (untyped) -> DrBox
    def pong: (untyped) -> DrBox
    %a{bc2cpp:hint}
    def hinted: () -> Integer
  end
  module DrK
    CELL: Integer
    AREA: Integer
    TABLE: Array[Integer]
    BOX: DrBox
  end
RBS

BAD = <<~RUBY
  class DrBox
    def tag; :box; end
  end
  class DrSub < DrBox
  end
  class DrPa
    def kind; 1; end
  end
  class DrPb
    def kind; :b; end
  end
  class DrBad
    def initialize(flag); @flag = flag; end
    def nil_path; @flag ? 4 : nil; end
    def empty; end
    def wrong_class; @flag ? DrBox.new : DrSub.new; end
    def wrong_kind; @flag ? [1] : "x"; end
    def opaque(x); x.foo; end
    def renamed; 1; end
    alias_method :renamed2, :renamed
  end
  class DrPoly1
    def size_of; 1; end
  end
  class DrPoly2
    def size_of; @x.foo; end
  end
  module DrBadK
    TWICE = 1
    TWICE = 2
    NAME = "x"
  end
RUBY

BAD_SIG = <<~RBS
  class DrBad
    def nil_path: () -> Integer
    def empty: () -> Integer
    def wrong_class: () -> DrBox
    def wrong_kind: () -> Array
    def opaque: (untyped) -> Integer
    def renamed: () -> Integer
  end
  class DrPa
    def kind: () -> Integer
  end
  class DrPoly2
    def size_of: () -> Integer
  end
  module DrBadK
    TWICE: Integer
    NAME: Integer
    MISSING: Integer
  end
RBS

def line_of(source, needle)
  source.lines.index { |l| l.include?(needle) } + 1
end

# Bc2cppFixtureRuntime.generate's closed-world run, returning its whole stderr.
def Bc2cppFixtureRuntime.full_stderr_of_last_failure(source, dir, owners)
  src = File.join(dir, 'fixture.rb')
  File.write(src, source)
  env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1',
          'SKIP_UNSUPPORTED' => '1', 'ONLY_OWNERS' => owners.join(','),
          'NATIVE_SRCS' => Shellwords.join(closed_world_native_srcs),
          'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
          'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
          'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
          NomethodReviewed::ALLOW_ENV => 'allow' }
  _code, err, = generator_run(env, [src])
  err
end

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

generate = lambda do |dir, source, sig, owners|
  sig_dir = File.join(dir, 'sig')
  FileUtils.mkdir_p(sig_dir)
  File.write(File.join(sig_dir, 'fx.rbs'), sig) if sig
  saved = ENV.values_at('BC2CPP_SIG_DIRS', 'BC2CPP_SIG_ROOT')
  # Diagnostics relative to the fixture directory: the failure message keeps only the tail of stderr.
  ENV['BC2CPP_SIG_DIRS'] = sig ? sig_dir : ''
  ENV['BC2CPP_SIG_ROOT'] = dir
  begin
    Bc2cppFixtureRuntime.generate(source, dir, only_owners: owners)
  rescue RuntimeError
    # The failure message keeps only the tail of stderr; read the whole of it from the same run, repeated.
    [nil, Bc2cppFixtureRuntime.full_stderr_of_last_failure(source, dir, owners)]
  ensure
    ENV['BC2CPP_SIG_DIRS'], ENV['BC2CPP_SIG_ROOT'] = saved
  end
end

Dir.mktmpdir do |dir|
  puts '== positive: checked declarations add the proofs\' facts'
  code, err = generate.call(File.join(dir, 'good'), GOOD, GOOD_SIG, %w[DrBox DrOther DrCell DrRow DrFx])
  check.call('the good fixture compiles', !code.nil?)
  code ||= ''
  %w[count_a count_b items more make maybe_box ping pong].each do |m|
    check.call("DrFx##{m} is checked and adds its fact",
               err.match?(/DECLARED_RET DrFx##{Regexp.escape(m)} -> .*: checked, fact/))
  end
  check.call('a POLY Integer name declared on every definition is a fact (FIXNUM_RETURN_PROOF is MONO-only)',
             err.include?('DECLARED_RET DrCell#span_of -> Integer: checked, fact fixnum') &&
               err.include?('DECLARED_RET DrRow#span_of -> Integer: checked, fact fixnum') &&
               err.match?(/^  RET span_of$/))
  check.call('Integer returns join FIXNUM_RETURN_PROOF', err.match?(/^  RET count_a$/) && err.match?(/^  RET count_b$/))
  check.call('Array returns join ARRAY_RETURN_PROOF (an Array#+ result included)',
             err.match?(/^  ARET items$/) && err.match?(/^  ARET more$/))
  check.call('a declared Fixnum return devirtualizes its caller\'s arithmetic',
             body_of.call(code, 'DrFx', 'use_count').include?('operands proven Fixnum'))
  check.call('mutually recursive class returns check together and type an ivar (the least fixpoint cannot prove them)',
             err.include?('CLASS_HINT  DrFx#@kept  (DrBox)'))
  %w[DrK::CELL DrK::AREA DrK::TABLE DrK::BOX].each do |c|
    check.call("#{c} is checked and adds its fact", err.include?("DECLARED_CONST #{c}: ") &&
                 err[/DECLARED_CONST #{c}: .*$/].to_s.end_with?('checked, fact'))
  end
  check.call('MUL/DIV constant expressions join INTEGER_CONSTANT_PROOF',
             err.match?(/^  CONST CELL$/) && err.match?(/^  CONST AREA$/))
  check.call('a declared Integer constant devirtualizes its use',
             body_of.call(code, 'DrFx', 'use_cell').include?('operands proven Fixnum'))
  check.call('a %a{bc2cpp:hint} declaration is listed unchecked and adds no fact',
             err.include?('DECLARED_RET DrFx#hinted -> Integer: unchecked hint') && !err.match?(/^  RET hinted$/))
  check.call('no TC1010/TC1011 error on the good fixture', !err.match?(/error: .*\[TC101[01]\]/))

  puts '== negative: an unproven path is an error at its file:line and a build abort'
  code, err = generate.call(File.join(dir, 'bad'), BAD, BAD_SIG, %w[DrBox DrSub DrPa DrPb DrBad DrPoly1 DrPoly2])
  check.call('the build aborts', code.nil? && err.include?('DECLARED_CONSTANT_CHECK'))
  # The constant check runs first and aborts; the return check is run on its own below.
  check.call('a reassigned constant',
             err.include?("fixture.rb:#{line_of(BAD, 'TWICE = 2')}:1: error: DrBadK::TWICE: Integer") &&
                                       err.include?('reassigned'))
  check.call('a constant whose value is not an Integer',
             err.include?("fixture.rb:#{line_of(BAD, 'NAME = "x"')}:1: error: DrBadK::NAME"))
  check.call('a declared constant the program never assigns',
             err.include?('DrBadK::MISSING: Integer') && err.include?('no assignment'))
  bad_sig = BAD_SIG.sub(/^module DrBadK.*\z/m, "")
  code, err = generate.call(File.join(dir, 'bad2'), BAD, bad_sig, %w[DrBox DrSub DrPa DrPb DrBad DrPoly1 DrPoly2])
  check.call('the return check aborts the build', code.nil? && err.include?('DECLARED_RETURN_CHECK'))
  located = lambda do |needle, what|
    err[/fixture\.rb:#{line_of(BAD, needle)}:1: error: .*/].to_s.include?(what)
  end
  check.call('a nil path', located.call('def nil_path', 'a path returns nil'))
  check.call('an empty body is a nil path', located.call('def empty;', 'a path returns nil'))
  check.call('a wrong-class path (a subclass is not exactly the class)',
             located.call('def wrong_class', 'is a DrSub, not exactly DrBox'))
  check.call('a wrong-kind path', located.call('def wrong_kind', 'not a proven Array'))
  check.call('an unverifiable call', located.call('def opaque', '(SEND0 :foo) is not a proven Fixnum'))
  check.call('an aliased (runtime-renamed) name refuses',
             err.match?(/fx\.rbs:7:\d+: error: DrBad#renamed -> Integer: cannot be checked: .*aliased/))
  check.call('a POLY name declared on one definition is checked per definition and adds no fact',
             err.include?('DECLARED_RET DrPa#kind -> Integer: checked, no fact') &&
             err.match?(/info: DrPa#kind -> Integer: POLY `kind`/))
  check.call('a POLY definition that does not hold is an error at its line',
             located.call('def size_of; @x.foo', 'DrPoly2#size_of'))
  check.call('the failures are TC1010', err.scan(/error: .*\[TC1010\]/).size >= 7)

  puts '== the type check reports the same diagnostics'
  fx = File.join(dir, 'tc', 'fx.rb')
  FileUtils.mkdir_p(File.join(dir, 'tc', 'sig'))
  File.write(fx, BAD)
  File.write(File.join(dir, 'tc', 'sig', 'fx.rbs'), BAD_SIG)
  out, st = Open3.capture2e({ 'MRBC' => ENV['MRBC'] }, RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/type_check.rb'),
                            '--no-sends',
                            '-q', '--sig', File.join(dir, 'tc', 'sig'), '--files', fx, chdir: File.join(dir, 'tc'))
  check.call('type_check exits 1', st.exitstatus == 1)
  check.call('a return path is TC1010 at its Ruby line',
             out.include?("fx.rb:#{line_of(BAD, 'def nil_path')}:1: error: DrBad#nil_path") &&
                                                            out.include?('[TC1010]'))
  check.call('a constant is TC1011 at its Ruby line',
             out.include?("fx.rb:#{line_of(BAD, 'TWICE = 2')}:1: error: DrBadK::TWICE") &&
                                                         out.include?('[TC1011]'))
  check.call('a checked constant is no longer noted as giving no hint',
             !out.match?(/Constant (TWICE|NAME) is accepted but gives no hint/))

  puts '== without declarations nothing is checked'
  code, err = generate.call(File.join(dir, 'none'), GOOD, nil, %w[DrBox DrOther DrCell DrRow DrFx])
  check.call('no DECLARED_RET / DECLARED_CONST section',
             code && !err.include?('DECLARED_RET') && !err.include?('DECLARED_CONST'))
  check.call('the facts the declarations added are absent',
             !err.match?(/^  RET span_of$/) && !err.match?(/^  CONST AREA$/) &&
                                                              !err.include?('CLASS_HINT  DrFx#@kept'))
end

if failures.empty?
  puts 'declared_return_check: all checks passed'
else
  puts "declared_return_check: #{failures.size} failure(s)"
  exit 1
end
