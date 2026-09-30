#!/usr/bin/env ruby
# frozen_string_literal: true

# ENTRY_ARG_CLASS_POOL (docs/adr/0282): a receiver that is a method parameter takes
# the class EVERY call site passes there.
#
# 1. Host only: the scoped hint table JoinDominance.entry_class reads.
# 2. With MRBC: the generated code of a closed-world fixture. Positive cases (one
#    caller, several callers of one class, a pass-through chain, recursion, a block
#    parameter, an Array) dispatch with no guard and no dynamic send (exact) or with
#    the guard (nil-tolerant and default-argument cases). Negative cases keep the
#    unresolved dispatch: another class at one site, a call by `send`/`method`/
#    alias/`instance_method`, a super call from a subclass, a keyword or splat
#    site, a rest or keyword parameter, a name a script can call (RGSS, Object,
#    a core class), an argument no proof covers.
# 3. With BC2CPP_MRUBY_CORE and g++: the fixture runs on real mruby, interpreted and
#    compiled, and must answer alike, exceptions included.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp_arg_class_pool_check.rb

require 'set'
require 'tmpdir'
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'
require_relative '../tools/bc2cpp/dispatch_targets'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '-- JoinDominance.entry_class (host)'
table = { ['m', 1] => 'Foo', ['m', 2] => ['Bar', true] }
check.call('outside a guarded consumer the pooled class is invisible',
           JoinDominance.entry_class('m', 1).nil?)
JoinDominance.guarded(table) do
  check.call('a guarded consumer sees the class', JoinDominance.entry_class('m', 1) == 'Foo')
  check.call('a [class, nilable] fact yields the class', JoinDominance.entry_class('m', 2) == 'Bar')
  check.call('an argument nothing pooled has no class', JoinDominance.entry_class('m', 3).nil?)
  JoinDominance.guarded do
    check.call('a nested guarded consumer inherits the table', JoinDominance.entry_class('m', 1) == 'Foo')
  end
  JoinDominance.guarded({ ['m', 1] => 'Baz' }) do
    check.call('a nested table shadows the outer one', JoinDominance.entry_class('m', 1) == 'Baz')
  end
  check.call('and the outer table is back after it', JoinDominance.entry_class('m', 1) == 'Foo')
end
check.call('the table does not outlive the block', JoinDominance.entry_class('m', 1).nil?)
begin
  JoinDominance.guarded(table) { raise 'boom' }
rescue RuntimeError => e
  check.call('an exception unwinds the scope too', e.message == 'boom' && !JoinDominance.guarded? &&
                                                   JoinDominance.entry_class('m', 1).nil?)
end

if ENV['MRBC']
  require_relative 'bc2cpp_fixture_runtime'
  runtime = Bc2cppFixtureRuntime

  fixture = <<~RUBY
    class ApItem
      def label; "item"; end
    end
    class Array
      def ap_twice; size * 2; end
    end
    class Hash
      def ap_twice; size * 3; end
    end
    class ApFoe
      def label; "foe"; end
    end
    class ApGadget
      def label; "gadget"; end
    end

    class ApBox
      # positive: one caller, a literal `Klass.new`
      def ap_one(o)
        o.label
      end

      # positive: several callers, one class
      def ap_many(o)
        o.label
      end

      # positive: a pass-through chain
      def ap_outer(o)
        ap_inner(o)
      end

      def ap_inner(o)
        o.label
      end

      # positive: recursion (the argument is the method's own parameter)
      def ap_rec(o, n)
        n > 0 ? ap_rec(o, n - 1) : o.label
      end

      # positive: mutual recursion
      def ap_ping(o, n)
        n > 0 ? ap_pong(o, n - 1) : o.label
      end

      def ap_pong(o, n)
        ap_ping(o, n)
      end

      # positive: a block parameter does not disturb the positional ones
      def ap_blk(o, &blk)
        blk.call
        o.label
      end

      # positive: an Array literal at every site
      def ap_arr(list)
        list.ap_twice
      end

      # guarded hint: nil at one site keeps the guard
      def ap_nilable(o)
        o.label
      end

      # guarded hint: the default expression joins the sites
      def ap_default(o = ApItem.new)
        o.label
      end

      # NEG: the default is another class than the sites pass
      def ap_default_other(o = ApFoe.new)
        o.label
      end

      # NEG: one site passes another class
      def ap_mixed(o)
        o.label
      end

      # NEG: reachable by send(:name)
      def ap_sent(o)
        o.label
      end

      # NEG: reachable by method(:name)
      def ap_meth(o)
        o.label
      end

      # NEG: reachable by a string name
      def ap_strsent(o)
        o.label
      end

      # NEG: instance_method / define_method
      def ap_dm(o)
        o.label
      end

      # NEG: alias
      def ap_orig(o)
        o.label
      end
      alias ap_alias ap_orig

      # NEG: a keyword pair at one site
      def ap_kwsite(o, extra = nil)
        o.label
      end

      # NEG: a splat at one site
      def ap_splat(o, extra = nil)
        o.label
      end

      # NEG: a keyword parameter
      def ap_kwparam(o, flag: false)
        o.label
      end

      # NEG: a rest parameter
      def ap_restparam(o, *more)
        o.label
      end

      # NEG: an argument read from data
      def ap_data(o)
        o.label
      end

      # NEG: an argument a block hands over
      def ap_fromblock(o)
        o.label
      end

      # NEG: the parameter is overwritten before the use
      def ap_reassigned(o)
        o = ApFoe.new if o.nil?
        o.label
      end

      # NEG: a method nobody calls has no call site to pool
      def ap_uncalled(o)
        o.label
      end

      # Never run (the bare core has neither `method` nor `instance_method`); it
      # only has to exist for the compiler to see the names.
      def ap_poison
        method(:ap_meth).call(ApFoe.new)
        self.class.instance_method(:ap_dm).bind(self).call(ApFoe.new)
      end

      def ap_run
        out = []
        out << ap_one(ApItem.new)
        out << ap_many(ApItem.new)
        out << ap_many(ApItem.new)
        out << ap_outer(ApGadget.new)
        out << ap_rec(ApItem.new, 3)
        out << ap_ping(ApFoe.new, 2)
        out << ap_blk(ApItem.new) { 1 }
        out << ap_arr([1, nil, 2])
        out << ap_arr([])
        out << ap_nilable(ApItem.new)
        out << ap_default(ApItem.new)
        out << ap_default
        out << ap_default_other(ApItem.new)
        out << ap_default_other
        out << ap_mixed(ApItem.new)
        out << ap_mixed(ApFoe.new)
        out << ap_sent(ApItem.new)
        out << send(:ap_sent, ApFoe.new)
        out << ap_meth(ApItem.new)
        out << ap_strsent(ApItem.new)
        out << send("ap_strsent", ApFoe.new)
        out << ap_dm(ApItem.new)
        out << ap_orig(ApItem.new)
        out << ap_alias(ApFoe.new)
        out << ap_kwsite(ApItem.new)
        out << ap_kwsite(ApItem.new, k: ApFoe.new).class.to_s
        out << ap_splat(ApItem.new)
        args = [ApFoe.new]
        out << ap_splat(*args)
        out << ap_kwparam(ApItem.new)
        out << ap_kwparam(ApItem.new, flag: true)
        out << ap_restparam(ApItem.new)
        out << ap_data({ x: ApFoe.new }[:x])
        [ApItem.new, ApFoe.new].each { |e| out << ap_fromblock(e) }
        out << ap_reassigned(ApItem.new)
        out << ap_reassigned(nil)
        out
      end
    end

    class ApBase
      def ap_sup(o)
        o.label
      end
    end

    class ApSub < ApBase
      def ap_sup(o)
        super(ApFoe.new)
      end
    end

    # NEG: names a script can call are never pooled
    module Kernel
      def ap_kern(o)
        o.label
      end
    end

    class Object
      def ap_top(o)
        o.label
      end
    end

    class Array
      def ap_core(o)
        o.label
      end
    end

    class ApDrv
      def ap_go_nil
        ApBox.new.ap_nilable(nil)
      end

      def ap_go
        out = ApBox.new.ap_run
        b = ApBase.new
        out << b.ap_sup(ApItem.new)
        out << ApSub.new.ap_sup(ApItem.new)
        out << ap_kern(ApItem.new)
        out << ap_top(ApItem.new)
        out << [].ap_core(ApItem.new)
        out
      end
    end
  RUBY

  chunk_of = lambda do |code, owner_method|
    code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|^static mrb_value \S+_block_fallback_|\z)/m].to_s
  end
  exact_tag = %r{// CLOSED_WORLD_EXACT_CLASS :\w+ -> \S+ \(pooled entry argument}
  typed_tag = %r{// TYPED :\w+ -> }

  puts '-- generated code (closed world)'
  code = nil
  err = nil
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(fixture, dir, closed: true)
  end
  exact = ->(method) { chunk_of.call(code, method).match?(exact_tag) }
  guarded = ->(method) { c = chunk_of.call(code, method); c.match?(typed_tag) && !c.match?(exact_tag) }
  plain = ->(method) { c = chunk_of.call(code, method); !c.empty? && !c.match?(exact_tag) && !c.match?(typed_tag) }
  # No unguarded direct call; a guarded hint the baseline already had is not the pool's.
  not_exact = ->(method) { c = chunk_of.call(code, method); !c.empty? && !c.match?(exact_tag) }
  facts = err.lines.grep(/ARGCLASS /).join

  check.call('one caller passing a fresh `Klass.new`: unguarded direct call', exact.call('ApBox#ap_one'))
  check.call('several callers of one class: unguarded direct call', exact.call('ApBox#ap_many'))
  check.call('a pass-through chain: the inner parameter takes the outer\'s class', exact.call('ApBox#ap_inner'))
  check.call('recursion: the argument is the method\'s own parameter', exact.call('ApBox#ap_rec'))
  check.call('mutual recursion', exact.call('ApBox#ap_ping') && exact.call('ApBox#ap_pong') == false)
  check.call('a block parameter does not disturb the positional ones', exact.call('ApBox#ap_blk'))
  # A builtin class keeps its guard: a native definer of the name could shadow the
  # Ruby definition (closed_world_exact_target), so only the hint applies.
  check.call('an Array literal at every site: the class is pooled, the builtin keeps its guard',
             guarded.call('ApBox#ap_arr') && facts.include?('ARGCLASS exact ApBox#ap_arr arg1 (Array)'))
  check.call('nil at one site: the class is a guarded hint', guarded.call('ApBox#ap_nilable'))
  check.call('a default of the same class joins the sites: guarded hint', guarded.call('ApBox#ap_default'))
  check.call('the diagnostic lists the exact and the hint facts',
             facts.include?('ARGCLASS exact ApBox#ap_one arg1 (ApItem)') &&
               facts.include?('ARGCLASS exact ApBox#ap_nilable arg1 (ApItem|nil)') &&
               facts.include?('ARGCLASS hint ApBox#ap_nilable arg1 (ApItem)'))

  check.call('NEG: a default of another class than the sites is no unguarded call', not_exact.call('ApBox#ap_default_other'))
  check.call('NEG: another class at one site', plain.call('ApBox#ap_mixed'))
  check.call('NEG: reachable by send(:name)', plain.call('ApBox#ap_sent'))
  check.call('NEG: reachable by method(:name)', plain.call('ApBox#ap_meth'))
  check.call('NEG: reachable by a string name', plain.call('ApBox#ap_strsent'))
  check.call('NEG: reachable by instance_method', plain.call('ApBox#ap_dm'))
  check.call('NEG: reachable by an alias', plain.call('ApBox#ap_orig'))
  check.call('NEG: a keyword pair at one site', plain.call('ApBox#ap_kwsite'))
  check.call('NEG: a splat at one site', plain.call('ApBox#ap_splat'))
  check.call('NEG: a keyword parameter', plain.call('ApBox#ap_kwparam'))
  check.call('NEG: a rest parameter', plain.call('ApBox#ap_restparam'))
  check.call('NEG: an argument read from data', plain.call('ApBox#ap_data'))
  check.call('NEG: an argument a block hands over', plain.call('ApBox#ap_fromblock'))
  check.call('NEG: a parameter overwritten before the use is not the pooled one', not_exact.call('ApBox#ap_reassigned'))
  check.call('NEG: a method no site calls', plain.call('ApBox#ap_uncalled'))
  check.call('NEG: a name a subclass redefines and reaches by super', plain.call('ApBase#ap_sup'))
  check.call('NEG: a method of Kernel', plain.call('Kernel#ap_kern'))
  check.call('NEG: a method of Object', plain.call('Object#ap_top'))
  check.call('NEG: a method of a core class', plain.call('Array#ap_core'))

  full = runtime.full
  core = runtime.core
  if (full.nil? && core.nil?) || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_CORE or BC2CPP_MRUBY_FULL (libmruby*.a and include/, from the patched 3rd/mruby) ' \
         'and have g++'
  else
    puts '-- fixture on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      owners = %w[ApBox ApBase ApSub ApDrv ApItem ApFoe ApGadget Array Hash Object Kernel]
      _code, err = runtime.generate(fixture, dir, closed: true, only_owners: owners)
      body = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "ApDrv"), 0, nullptr);
          call(M, "go", drv, "ap_go");
          call(M, "go nil", drv, "ap_go_nil");
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, owners, body, build: full || core, full: !full.nil?)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('every method answers what the interpreter answers, values and exceptions alike',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp arg class pool check: PASS'
else
  warn "bc2cpp arg class pool check: #{failures.size} failure(s)"
  exit 1
end
