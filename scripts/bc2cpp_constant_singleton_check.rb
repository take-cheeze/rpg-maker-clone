#!/usr/bin/env ruby
# frozen_string_literal: true

# CONSTANT_SINGLETON (docs/adr/0281): a send whose receiver is a stable class or
# module constant reaches its singleton method without dispatch, both for
# Ruby-defined singleton methods (CLOSED_WORLD_CONSTANT_OBJECT) and, through the
# audited NativeDirect entries, for RGSS natives (NATIVE_SINGLETON_DIRECT).
#
# 1. With MRBC: the generated code for fixtures. A constant load inside a loop
#    that also holds a `break` (a JMPUW edge) still resolves; each way the
#    constant or its singleton lookup can change at run time keeps the dispatch.
# 2. With MRBC, BC2CPP_MRUBY_FULL and g++: the fixtures run against real mruby,
#    interpreted and compiled, and must answer alike.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_constant_singleton_check.rb

require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

if ENV['MRBC']
  require_relative 'bc2cpp_fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  body_of = lambda do |code, fn|
    code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  end

  LOOP_WORLD = <<~RUBY
    module CsCodec
      def self.read(list); list.shift; end
      def self.twice(list); list.shift; list.shift; end
    end
    class CsLoop
      # `break` inside a rescue body is a JMPUW, which used to make every
      # constant load after it unresolvable.
      def scan(list)
        out = []
        begin
          until list.empty?
            a = CsCodec.read(list)
            break if a == 0
            out << CsCodec.read(list)
          end
        rescue StopIteration
          out << :stop
        end
        out
      end
    end
  RUBY

  puts '-- constant load after a break in a rescue body'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(LOOP_WORLD, dir)
    # The rescue body is outlined into its own function, so count over the whole unit.
    check.call('both loads of the constant reach the singleton method directly',
               code.scan('CLOSED_WORLD_CONSTANT_OBJECT :read -> CsCodec.singleton#read').size == 2 &&
                 !code.match?(/POLY_DIAG[^\n]*name="read"/))
  end

  full = runtime.full
  if full.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(LOOP_WORLD, dir, closed: true, only_owners: %w[CsCodec.singleton CsLoop])
      body = <<~CPP
        static mrb_value ints(mrb_state* M, std::initializer_list<int> xs) {
          mrb_value list = mrb_ary_new(M);
          for (int x : xs) mrb_ary_push(M, list, mrb_fixnum_value(x));
          return list;
        }
        static int scenario(mrb_state* M) {
          mrb_value loop = mrb_obj_new(M, mrb_class_get(M, "CsLoop"), 0, nullptr);
          mrb_value a = ints(M, {3, 4, 5, 6, 0, 9});
          call(M, "scan stops at the zero", loop, "scan", 1, &a);
          mrb_value b = ints(M, {3, 4});
          call(M, "scan drains the list", loop, "scan", 1, &b);
          mrb_value c = ints(M, {});
          call(M, "scan of an empty list", loop, "scan", 1, &c);
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[CsCodec.singleton CsLoop], body, build: full, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('the compiled loop answers what the interpreter answers',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      end
    end
  end
else
  puts '  SKIP generated code: set MRBC (a host mrbc built from the patched 3rd/mruby)'
end

puts(failures.empty? ? 'bc2cpp_constant_singleton_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
