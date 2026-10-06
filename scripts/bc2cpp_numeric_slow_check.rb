#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0292: the else arm of a guarded numeric arm (FIXNUM_ARITHMETIC, FIXNUM_COMPARE, FLOAT_DIV_RECEIVER,
# INTEGER_LSHIFT, FIXNUM_SHIFT, FIXNUM_BINARY, INTEGER_UNARY) is a typed helper (bc2cpp_slow_<op>) that runs
# mruby's own numeric/bigint C entry point, and dispatches by name only for an operand class it does not own.
#
# 1. With MRBC: the generated code. Every such site in a method whose operands are unproven calls its helper
#    and has no by-name call of its own; the helper is defined once and holds the by-name fallback; a Ruby
#    redefinition of the operator (Integer#+, Float#-, Integer#<) puts the send back, and a proven site keeps
#    the NUMERIC_OPERAND_PROOF form without a helper.
# 2. With a full-core libmruby: the fixture's methods, compiled and interpreted, answer alike -- values
#    (Float bits included: -0.0, NaN), result representation (Integer#hash), exception class and message --
#    over a matrix of Fixnum / heap Integer / bigint / Float / nil / String / Array / user-class operands,
#    negative and oversized shift counts, floor division and modulo signs, at the top and bottom of the
#    Fixnum and mrb_int ranges. A numeric operand pair makes no by-name call, a bigint result leaves at most
#    one GC arena entry, and a loop of bigint arithmetic survives GC. The run repeats on a build whose
#    mrb_int is 32 bits (BC2CPP_MRUBY_FULL32, BC2CPP_MRBC32; -DMRB_32BIT -DMRB_INT32: 31-bit Fixnums) and,
#    with BC2CPP_MRUBY_NOBIGINT, on a build without mruby-bigint (where the bigint arms vanish).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32
#         BC2CPP_MRUBY_NOBIGINT=dir] ruby scripts/bc2cpp_numeric_slow_check.rb

require 'tmpdir'
require_relative 'bc2cpp_fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

OPS = {
  'add' => '+', 'sub' => '-', 'mul' => '*', 'div' => '/', 'mod' => '%', 'band' => '&', 'bor' => '|',
  'bxor' => '^', 'lsh' => '<<', 'rsh' => '>>', 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>='
}.freeze
UNARY = { 'neg' => '-a', 'zero' => 'a.zero?', 'rnd' => 'a.round' }.freeze
HELPER = { '+' => 'add', '-' => 'sub', '*' => 'mul', '/' => 'div', '%' => 'mod', '&' => 'and', '|' => 'or',
           '^' => 'xor', '<<' => 'lshift', '>>' => 'rshift', '<' => 'lt', '<=' => 'le', '>' => 'gt', '>=' => 'ge' }.freeze

def open_methods
  OPS.map { |name, op| "    def #{name}(a, b) = a #{op} b" }.join("\n") + "\n" +
    UNARY.map { |name, expr| "    def #{name}(a) = #{expr}" }.join("\n")
end

FIXTURE = <<~RUBY
  class NsBox
    # Operators only a non-numeric receiver answers; the matrix below sends them numbers too.
    def +(o) = :box_add
    def -(o) = :box_sub
    def *(o) = :box_mul
    def /(o) = :box_div
    def <<(o) = :box_lsh
    def >>(o) = :box_rsh
    def inspect = "box"
  end

  class NsCmp
    include Comparable
    def <=>(o) = 0
    def inspect = "cmp"
  end

  # Called only from the driver, so no operand is proven.
  class NsOpen
  #{open_methods}

    def arena(a, b)
      w = NsProbe.arena
      a + b
      x = NsProbe.arena - w
      w = NsProbe.arena
      a - b
      y = NsProbe.arena - w
      w = NsProbe.arena
      a * b
      z = NsProbe.arena - w
      w = NsProbe.arena
      a / b
      q = NsProbe.arena - w
      w = NsProbe.arena
      a % b
      m = NsProbe.arena - w
      w = NsProbe.arena
      a << 3
      s = NsProbe.arena - w
      w = NsProbe.arena
      -a
      n = NsProbe.arena - w
      [x, y, z, q, m, s, n].max
    end

    def dispatched(a, b, op)
      w = NsProbe.dispatches
      case op
      when 0 then a + b
      when 1 then a - b
      when 2 then a * b
      when 3 then a / b
      when 4 then a % b
      when 5 then a & b
      when 6 then a | b
      when 7 then a ^ b
      when 8 then a << b
      when 9 then a >> b
      when 10 then a < b
      when 11 then a <= b
      when 12 then a > b
      when 13 then a >= b
      when 14 then -a
      when 15 then a.zero?
      when 16 then a.round
      end
      NsProbe.dispatches - w - 1 # the second probe call is itself one dispatch
    end
  end

  # Every operand here is proven an Integer or Float, so the sites keep the proof's form, no helper.
  class NsProven
    def run
      x = 7
      y = 2.5
      [x + 1, x * x, x - 3, y * 2, x < 9, y > 1.0, x / 2]
    end
  end
RUBY

FIXTURE_BIG = <<~RUBY
  class NsBig
    def churn(seed, n)
      acc = seed
      i = 0
      while i < n
        acc = (acc * 3 + i) % 340282366920938463463374607431768211457
        acc = acc >> 1 if i % 7 == 0
        acc = acc | 1
        acc = acc ^ 5
        acc = acc & 340282366920938463463374607431768211455
        acc = acc - 11 if acc > 99
        GC.start if i % 50 == 0
        i += 1
      end
      acc
    end

    def grow(seed, n)
      acc = seed
      n.times { acc = acc * 7 + 1 }
      acc
    end
  end
RUBY

# NUMERIC_SLOW_CLOSED (ADR 0360): no class of this world answers `/` except Integer and Float, so the helper's
# else is a proven NoMethodError instead of a by-name call. NsDivBox has no `/` (NsBox in FIXTURE does).
FIXTURE_DIV = <<~RUBY
  class NsDivBox
    def inspect = "divbox"
  end
  class NsDiv
    def div(a, b) = a / b
  end
RUBY

# Redefined operators: the arm must not be taken, the program's own method must still run.
REDEFINED = <<~RUBY
  class Integer
    def +(o) = :int_plus
  end
  class Float
    def -(o) = :flo_minus
  end
  class NsRe
    def add(a, b) = a + b
    def sub(a, b) = a - b
    def mul(a, b) = a * b
  end
RUBY
REDEFINED_CMP = <<~RUBY
  class Integer
    def <(o) = :int_lt
  end
  class NsReCmp
    def lt(a, b) = a < b
    def gt(a, b) = a > b
  end
RUBY

# Top Fixnum / mrb_int per build, as literals (AGENTS.md: a computed constant that crosses 32 bits breaks irep load).
# `:nobig` is the default-width build without mruby-bigint, where mrb_int is 32 bits wide and every Integer is a Fixnum.
WIDTHS = { 64 => { fmax: '4611686018427387903' }, 32 => { fmax: '1073741823' }, nobig: { fmax: '2147483647' } }.freeze

def driver(width)
  w = WIDTHS.fetch(width)
  <<~RUBY
    FM = #{w[:fmax]}
    IM = $bigint ? FM * 2 + 1 : FM # mrb_int max, computed: a parser without mruby-bigint rejects the 64-bit literal
    $vals = [0, 1, -1, 2, -2, 3, 7, -7, 10, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -1.5, 3.0,
             1.0e19, -1.0e19, Float::NAN, Float::INFINITY, -Float::INFINITY, nil, "s", [1], NsBox.new, NsCmp.new]
    $vals += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * 2, IM * IM, -(IM * IM), 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
    $counts = [0, 1, -1, 2, 5, 30, 31, 32, 33, 62, 63, 64, 65, 100, -2, -30, -31, -32, -62, -63, -64, -65, -100, -IM,
               -IM - 1, 2.5, -2.5, nil, "s", 1.0e19]
    $counts += [2 ** 100] if $bigint
    # The operand classes a helper owns, so the compiled run makes no by-name call for them.
    def owned(op, a, b)
      ca = a.is_a?(Float) ? :flt : (a.is_a?(Integer) ? :int : nil)
      cb = b.is_a?(Float) ? :flt : (b.is_a?(Integer) ? :int : nil)
      return false unless ca
      case op
      when 'add', 'sub', 'mul', 'div' then !cb.nil?
      when 'lt', 'le', 'gt', 'ge' then true
      when 'mod', 'band', 'bor', 'bxor' then ca == :int && cb == :int && !(op == 'mod' && b == 0)
      else false
      end
    end
    # `"s" * 2**62` and `[1] * 2**62` exhaust memory in the interpreter as well.
    def skip_repeat(op, a, b)
      op == 'mul' && (a.is_a?(String) || a.is_a?(Array)) && b.is_a?(Integer) && b.abs > 1000
    end
    def fmt(v)
      s = v.inspect
      s += " h=\#{v.hash}" if v.is_a?(Integer)
      s
    end
    def try
      fmt(yield)
    rescue => e
      "\#{e.class}: \#{e.message}"
    end
    o = NsOpen.new
    %w[add sub mul div mod band bor bxor lt le gt ge].each do |op|
      $vals.each do |a|
        $vals.each do |b|
          next if skip_repeat(op, a, b)
          puts "\#{op} \#{a.inspect} \#{b.inspect} => \#{try { o.send(op, a, b) }}"
        end
      end
    end
    %w[lsh rsh].each do |op|
      ($vals.grep(Integer) + [0.5, nil, "s"]).each do |a|
        $counts.each { |b| puts "\#{op} \#{a.inspect} \#{b.inspect} => \#{try { o.send(op, a, b) }}" }
      end
    end
    %w[neg zero rnd].each { |op| $vals.each { |a| puts "\#{op} \#{a.inspect} => \#{try { o.send(op, a) }}" } }
    puts 'end'
  RUBY
end

def generated_checks(check, runtime)
  puts '-- generated code (closed world)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE, dir, closed: true, only_owners: %w[NsOpen NsProven NsBox NsCmp])
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    OPS.each do |name, op|
      c = chunk.call("NsOpen##{name}")
      key = HELPER.fetch(op)
      check.call("NsOpen##{name}: `#{op}` calls bc2cpp_slow_#{key} and has no by-name call of its own",
                 c.match?(/bc2cpp_slow_#{key}(?:_f)?\(M, /) && !c.include?('bc2cpp_send(') && !c.include?('mrb_funcall('))
      helper = code[/^static mrb_value bc2cpp_slow_#{key}(?:_f)?\(mrb_state\* M.*?^\}\n/m].to_s
      check.call("bc2cpp_slow_#{key} is defined once and dispatches the operands it does not own",
                 code.scan(/^static mrb_value bc2cpp_slow_#{key}(?:_f)?\(/).size == 1 && helper.include?('bc2cpp_send('))
    end
    UNARY.each_key do |name|
      c = chunk.call("NsOpen##{name}")
      key = { 'neg' => 'neg', 'zero' => 'zero', 'rnd' => 'round' }.fetch(name)
      check.call("NsOpen##{name}: INTEGER_UNARY calls bc2cpp_slow_#{key}, no by-name call of its own",
                 c.match?(/bc2cpp_slow_#{key}(?:_f)?\(M, /) && !c.include?('bc2cpp_send(') && !c.include?('mrb_funcall('))
    end
    check.call('the Float receiver joins the +,-,* helpers and -@ when Float has no Ruby definition',
               code.include?('bc2cpp_slow_add_f(') && code.include?('bc2cpp_slow_neg_f('))
    check.call('the helpers release the GC arena (restore, then protect the result)',
               code[/^static mrb_value bc2cpp_slow_add_f\(.*?^\}\n/m].to_s.match?(/mrb_gc_arena_restore\(M, ai\);\s+mrb_gc_protect\(M, r\);/))
    check.call('bigint calls are guarded by MRB_USE_BIGINT and declared extern "C"',
               code.include?('#ifdef MRB_USE_BIGINT') && code.include?('extern "C" mrb_value mrb_bint_lshift'))
    proven = chunk.call('NsProven#run')
    check.call('a proven site keeps NUMERIC_OPERAND_PROOF and gets no helper',
               !proven.include?('bc2cpp_slow_') && !proven.include?('bc2cpp_send('))
    check.call('a non-numeric receiver still reaches a user-defined operator (NsBox) through the helper',
               code.include?('bc2cpp_send(M, a'))
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(REDEFINED, dir, closed: true, only_owners: %w[NsRe])
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    check.call('NEG: Integer#+ redefined in Ruby keeps the by-name call (no helper)',
               chunk.call('NsRe#add').include?('bc2cpp_send(') && !chunk.call('NsRe#add').include?('bc2cpp_slow_add'))
    check.call('Integer#+ redefined leaves `*` on its helper', chunk.call('NsRe#mul').include?('bc2cpp_slow_mul'))
    sub = chunk.call('NsRe#sub')
    check.call('NEG: Float#- redefined takes the Integer-only helper (the Float receiver keeps its by-name call)',
               sub.include?('bc2cpp_slow_sub(M') && !sub.include?('bc2cpp_slow_sub_f('))
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(REDEFINED_CMP, dir, closed: true, only_owners: %w[NsReCmp])
    lt = code[/^\/\/ NsReCmp#lt \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    check.call('NEG: Integer#< redefined keeps the by-name call', lt.include?('bc2cpp_send(') && !lt.include?('bc2cpp_slow_lt'))
  end
end

# The `/` helper of a world where only Integer and Float answer it.
def closed_div_generated_checks(check, runtime)
  puts '-- generated code (closed world, only Integer and Float answer `/`)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_DIV, dir, closed: true, only_owners: %w[NsDiv NsDivBox])
    call = code[/^\/\/ NsDiv#div \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    helper = code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:.*?^\}\n){2}\n*#endif\n/m].to_s
    check.call('NsDiv#div calls bc2cpp_slow_div and has no by-name call of its own',
               call.include?('bc2cpp_slow_div(M, ') && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
    closed = helper.split("#else\n", 2)[1].to_s
    check.call('bc2cpp_slow_div holds no by-name call: any other receiver is a proven NoMethodError',
               !helper.empty? && !closed.empty? && !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') &&
               closed.include?('bc2cpp_nomethod'))
    check.call('bc2cpp_slow_div keeps the by-name helper for a build with Complex or Rational operands',
               helper.start_with?('#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)') &&
               helper.split("#else\n", 2).first.include?('mrb_funcall(M, a, "/"'))
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_DIV}class NsDivBox\n  def /(o) = :divbox\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: %w[NsDiv NsDivBox])
    helper = code[/^static mrb_value bc2cpp_slow_div\(mrb_state\* M.*?^\}\n/m].to_s
    check.call('NEG: a user class answering `/` keeps the by-name call in the helper', helper.include?('bc2cpp_send('))
  end
end

def div_driver(width)
  <<~RUBY
  FM = #{WIDTHS.fetch(width)[:fmax]}
  $vals = [0, 1, -1, 2, -2, 7, -7, FM, -FM, FM - 1, 0.0, -0.0, 0.5, -1.5, 3.0, 1.0e19, Float::NAN, Float::INFINITY,
           -Float::INFINITY, nil, true, false, "s", :sym, [1], {a: 1}, 1..2, NsDivBox.new, NsDivBox, Object.new]
  $vals += [FM + 1, -FM - 2, 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
  def try
    v = yield
    s = v.inspect
    s += " h=\#{v.hash}" if v.is_a?(Integer)
    s
  rescue => e
    "\#{e.class}: \#{e.message}"
  end
  o = NsDiv.new
  $vals.each { |a| $vals.each { |b| puts "div \#{a.inspect} \#{b.inspect} => \#{try { o.div(a, b) }}" } }
  puts 'end'
  RUBY
end

DIV_SCENARIO = <<~CPP
  #include <string>
  static mrb_value div_body(mrb_state* M, void* ud) {
    mrb_value* ab = (mrb_value*)ud;
    return bc2cpp_slow_div(M, ab[0], ab[1]);
  }
  static mrb_value div_method(mrb_state* M, void* ud) {
    mrb_value* ab = (mrb_value*)ud;
    return (mrb_funcall)(M, ab[0], "/", 1, ab[1]);
  }
  static std::string div_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
  }
  static int scenario(mrb_state* M) {
    std::fflush(stdout);
    const char* src = R"BCD(__SOURCE__)BCD";
    mrb_load_string(M, src);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    // The helper called directly against the method it stands for.
    mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
    int total = 0, bad = 0;
    for (mrb_int i = 0; i < RARRAY_LEN(vals); ++i) for (mrb_int j = 0; j < RARRAY_LEN(vals); ++j) {
      mrb_value ab[2] = { RARRAY_PTR(vals)[i], RARRAY_PTR(vals)[j] };
      int ai = mrb_gc_arena_save(M);
      mrb_bool e1 = FALSE, e2 = FALSE;
      std::string g = div_describe(M, mrb_protect_error(M, div_body, ab, &e1), e1);
      std::string w = div_describe(M, mrb_protect_error(M, div_method, ab, &e2), e2);
      mrb_gc_arena_restore(M, ai);
      ++total;
      if (g != w) {
        ++bad;
        if (bad <= 8) std::printf("  H MISMATCH %s vs %s\\n", g.c_str(), w.c_str());
      }
    }
    std::printf("  H summary %d cases, %d mismatches\\n", total, bad);
    return 0;
  }
CPP

unless runtime.mrbc && system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

generated_checks(check, runtime)
closed_div_generated_checks(check, runtime)

# [label, build dir, mrbc, extra flags, width, bigint?]
builds = []
# BC2CPP_MRUBY_FULL, or a full-core mruby built into BC2CPP_FULL_BUILD_DIR (the core-mrbtest shard shares it).
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds <<['mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT', 64, true] if full && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT', 32, true]
end
if ENV['BC2CPP_MRUBY_NOBIGINT'] && runtime.compiler?
  builds << ['no mruby-bigint (32-bit mrb_int, no heap Integers)', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], '', :nobig, false]
end
puts '-- SKIP run: set BC2CPP_MRUBY_FULL (full-core libmruby.a) and have g++' if builds.empty?

PROBE = <<~CPP
  static mrb_value probe_arena(mrb_state* M, mrb_value) { return mrb_fixnum_value(mrb_gc_arena_save(M)); }
  static mrb_value probe_dispatches(mrb_state* M, mrb_value) { return mrb_fixnum_value(dispatches); }
CPP

# Each helper called directly (the generated TU is part of main.cpp) against the method it stands for, over the
# driver's operands: the pairs an operator opcode never hands to a helper (two Integers for `/`, heap Integers
# for `+`) get the same scrutiny. Differences by design: two Integers add/sub/mul as vm.c OP_MATH, so an
# MRB_INT_MIN operand (wrong in the 32-bit bigint core's Integer#+) is skipped there, and without bigint
# only the class of the overflow RangeError is compared (the VM and the method word it differently).
HELPER_MATRIX = <<~CPP
  #include <string>
  struct HelperCase {
    const char* name;
    const char* op;
    mrb_value (*bin)(mrb_state*, mrb_value, mrb_value);
    mrb_value (*un)(mrb_state*, mrb_value);
    int kind;  // 0 arithmetic, 1 compare, 2 shift, 3 other binary, 4 unary
  };
  static const HelperCase helper_cases[] = {
    { "add", "+", bc2cpp_slow_add_f, nullptr, 0 }, { "sub", "-", bc2cpp_slow_sub_f, nullptr, 0 },
    { "mul", "*", bc2cpp_slow_mul_f, nullptr, 0 }, { "div", "/", bc2cpp_slow_div, nullptr, 3 },
    { "mod", "%", bc2cpp_slow_mod, nullptr, 3 }, { "and", "&", bc2cpp_slow_and, nullptr, 3 },
    { "or", "|", bc2cpp_slow_or, nullptr, 3 }, { "xor", "^", bc2cpp_slow_xor, nullptr, 3 },
    { "lshift", "<<", bc2cpp_slow_lshift, nullptr, 2 }, { "rshift", ">>", bc2cpp_slow_rshift, nullptr, 2 },
    { "lt", "<", bc2cpp_slow_lt, nullptr, 1 }, { "le", "<=", bc2cpp_slow_le, nullptr, 1 },
    { "gt", ">", bc2cpp_slow_gt, nullptr, 1 }, { "ge", ">=", bc2cpp_slow_ge, nullptr, 1 },
    { "neg", "-@", nullptr, bc2cpp_slow_neg_f, 4 }, { "zero", "zero?", nullptr, bc2cpp_slow_zero, 4 },
    { "round", "round", nullptr, bc2cpp_slow_round, 4 },
  };
  struct HelperCall { const HelperCase* c; mrb_value a, b; bool method; };
  static mrb_value helper_body(mrb_state* M, void* ud) {
    HelperCall* k = (HelperCall*)ud;
    if (k->method) {
      if (k->c->kind == 4) return (mrb_funcall)(M, k->a, k->c->op, 0);
      return (mrb_funcall)(M, k->a, k->c->op, 1, k->b);
    }
    return k->c->kind == 4 ? k->c->un(M, k->a) : k->c->bin(M, k->a, k->b);
  }
  static std::string helper_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      std::string out = std::string("raised ") + mrb_obj_classname(M, v);
  #ifdef MRB_USE_BIGINT
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      out += ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
  #endif
      return out;
    }
    mrb_value s = mrb_inspect(M, v);
    std::string out(RSTRING_PTR(s), RSTRING_LEN(s));
    if (mrb_integer_p(v) || mrb_bigint_p(v)) {
      mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
      out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
    }
    return out;
  }
  static mrb_bool helper_int_min_operand(mrb_value v) {
    return mrb_integer_p(v) && mrb_integer(v) == MRB_INT_MIN;
  }
  static void helper_matrix(mrb_state* M) {
    mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
    mrb_value counts = mrb_gv_get(M, mrb_intern_lit(M, "$counts"));
    int total = 0, bad = 0;
    for (const HelperCase& c : helper_cases) {
      mrb_value rights = c.kind == 2 ? counts : vals;
      mrb_int nb = c.kind == 4 ? 1 : RARRAY_LEN(rights);
      for (mrb_int i = 0; i < RARRAY_LEN(vals); ++i) for (mrb_int j = 0; j < nb; ++j) {
        mrb_value a = RARRAY_PTR(vals)[i];
        mrb_value b = c.kind == 4 ? mrb_nil_value() : RARRAY_PTR(rights)[j];
        // `String#<<` and `Array#<<` mutate the receiver, so the second call would see the first's append.
        if (c.kind == 2 && (mrb_string_p(a) || mrb_array_p(a))) continue;
        // `"s" * 2**62` exhausts memory by either route.
        if (c.kind == 0 && mrb_type(a) != MRB_TT_INTEGER && mrb_type(a) != MRB_TT_FLOAT && mrb_type(a) != MRB_TT_BIGINT &&
            (mrb_integer_p(b) || mrb_bigint_p(b))) continue;
        if (c.kind == 0 && mrb_integer_p(a) && mrb_integer_p(b) && (helper_int_min_operand(a) || helper_int_min_operand(b))) continue;
        int ai = mrb_gc_arena_save(M);
        HelperCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
        mrb_bool e1 = FALSE, e2 = FALSE;
        mrb_value got = mrb_protect_error(M, helper_body, &got_call, &e1);
        std::string g = helper_describe(M, got, e1);
        mrb_value want = mrb_protect_error(M, helper_body, &want_call, &e2);
        std::string w = helper_describe(M, want, e2);
        mrb_gc_arena_restore(M, ai);
        ++total;
        if (g != w) {
          ++bad;
          if (bad <= 8) {
            mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
            std::printf("  H MISMATCH %s %.*s %.*s helper=%s method=%s\\n", c.name, (int)RSTRING_LEN(as), RSTRING_PTR(as),
                        (int)RSTRING_LEN(bs), RSTRING_PTR(bs), g.c_str(), w.c_str());
          }
        }
      }
    }
    std::printf("  H summary %d cases, %d mismatches\\n", total, bad);
  }
CPP

def scenario_body(source)
  <<~CPP
    #{PROBE}
    #{HELPER_MATRIX}
    static int scenario(mrb_state* M) {
      RClass* probe = mrb_define_module(M, "NsProbe");
      mrb_define_class_method(M, probe, "arena", probe_arena, MRB_ARGS_NONE());
      mrb_define_class_method(M, probe, "dispatches", probe_dispatches, MRB_ARGS_NONE());
      std::fflush(stdout);
      const char* src = R"BCD(#{source})BCD";
      mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      helper_matrix(M);
      return 0;
    }
  CPP
end

builds.each do |label, build, mrbc, flags, width, bigint|
  puts "-- fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      fixture = bigint ? FIXTURE + FIXTURE_BIG : FIXTURE
      _code, err = runtime.generate(fixture, dir, closed: true, only_owners: %w[NsOpen NsBox NsCmp NsProven NsBig])
      source = "$bigint = #{bigint}\n#{driver(width)}"
      if bigint
        source += <<~RUBY
          seed = 2 ** 70 + 12345
          puts "churn => \#{NsBig.new.churn(seed, 3000).inspect}"
          puts "churn small => \#{NsBig.new.churn(3, 300).inspect}"
          puts "grow => \#{NsBig.new.grow(seed, 200).to_s.size}"
          puts 'end big'
        RUBY
      end
      # Dispatch counts and arena depths: two-space lines, which the comparison skips.
      source += <<~RUBY
        o = NsOpen.new
        ops = %w[add sub mul div mod band bor bxor lsh rsh lt le gt ge]
        pool = $vals.first(31) + ($bigint ? $vals.last(10) : [])
        ops.each_with_index do |op, k|
          pool.each do |a|
            pool.each do |b|
              next if %w[lsh rsh].include?(op) && !(b.is_a?(Integer) && b.abs < 200)
              next if skip_repeat(op, a, b)
              n = begin; o.dispatched(a, b, k); rescue => e; -1; end
              puts "  D \#{op} \#{owned(op, a, b) ? 1 : 0} \#{a.inspect} \#{b.inspect} \#{n}"
            end
          end
        end
        [14, 15, 16].each do |k|
          pool.each do |a|
            # zero? on a bigint stays a by-name call (Numeric#zero? runs Integer#==, left to the method); so does round on a Float.
            own = a.is_a?(Float) ? (k != 16) : (a.is_a?(Integer) && k != 15)
            puts "  D un\#{k} \#{own ? 1 : 0} \#{a.inspect} nil \#{(o.dispatched(a, nil, k) rescue -1)}"
          end
        end
        ar = ($bigint ? [2 ** 70, -(2 ** 70), 2 ** 100 + 1] : [IM, -IM])
        ar.each { |a| ar.each { |b| puts "  A \#{a.inspect} \#{b.inspect} \#{(o.arena(a, b) rescue -1)}" } }
        puts 'end'
      RUBY
      built, output = runtime.run(dir, err, %w[NsOpen NsBox NsCmp NsProven NsBig], scenario_body(source), build: build, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      # Every helper called directly against the method it stands for (HELPER_MATRIX), in both runs.
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H MISMATCH /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its method called directly (#{summary.strip})",
                   summary.match?(/ (\d+) cases, 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 5000)
      end
      check.call("the matrix is large (#{strip.call(interpreted).size} answers)", strip.call(interpreted).size > 5000)
      same = strip.call(interpreted) == strip.call(compiled)
      check.call('every answer is the interpreter\'s: value, Float bits, Integer#hash, exception class and message', same)
      strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      errors = strip.call(interpreted).count { |l| l.include?('Error') }
      check.call("the matrix includes exceptions (#{errors})", errors > 100)
      if bigint
        check.call('a loop of bigint arithmetic survives GC and ends where the interpreter does',
                   interpreted.any? { |l| l.start_with?('churn =>') } && interpreted.include?('end big'))
        check.call('the interpreter really makes bigints (2**100 appears)',
                   interpreted.any? { |l| l.include?('1267650600228229401496703205376') })
      else
        check.call('without mruby-bigint an overflow is the interpreter\'s RangeError', interpreted.any? { |l| l.include?('RangeError') })
      end

      # A numeric operand pair the helper owns makes no by-name call in the compiled run.
      owned_lines = compiled.grep(/\A  D \S+ 1 /)
      # -1 marks a pair that raised (a zero divisor, an oversized shift): the count is lost with the frame.
      bad = owned_lines.reject { |l| %w[0 -1].include?(l.split.last) }
      check.call("operand pairs a helper owns make no by-name call (#{owned_lines.size} pairs)",
                 owned_lines.size > 500 && bad.empty? && owned_lines.count { |l| l.end_with?(' 0') } > 500)
      bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
      arena = compiled.grep(/\A  A /).map { |l| l.split.last.to_i }
      check.call("a bigint operation leaves at most one arena entry (#{arena.max})", !arena.empty? && arena.max <= 1)
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

builds.each do |label, build, mrbc, flags, width, bigint|
  puts "-- closed `/` helper on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(FIXTURE_DIV, dir, closed: true, only_owners: %w[NsDiv NsDivBox])
      source = "$bigint = #{bigint}\n#{div_driver(width)}"
      scenario = DIV_SCENARIO.sub('__SOURCE__') { source }
      built, output = runtime.run(dir, err, %w[NsDiv NsDivBox], scenario, build: build, full: true)
      check.call('the closed `/` fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      check.call("every `/` answer is the interpreter's (#{strip.call(interpreted).size} answers)",
                 strip.call(interpreted) == strip.call(compiled) && strip.call(interpreted).size > 500)
      strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call('the matrix has NoMethodError and TypeError rows',
                 interpreted.count { |l| l.include?('NoMethodError') } > 50 && interpreted.count { |l| l.include?('TypeError') } > 20)
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H MISMATCH /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("the helper agrees with Integer#/ and Float#/ called directly (#{summary.strip})",
                   summary.match?(/ 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 500)
      end
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp numeric slow-path check: PASS'
else
  warn "bc2cpp numeric slow-path check: #{failures.size} failure(s)"
  exit 1
end
