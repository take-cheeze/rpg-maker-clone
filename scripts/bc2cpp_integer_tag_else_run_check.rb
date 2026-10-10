#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ADR 0394 (INTEGER_TAG_ELSE) on real mruby: an exact Array receiver's non-fixnum index runs the native Array
# body directly (mrb_ary_aget1_impl / mrb_ary_aset2_impl), and every answer is the interpreter's: the value, the
# exception class and message, and the receiver's contents after `[]=`.
#
# Needs a full-core libmruby built from this tree's 3rd/mruby (the exposed bodies come from patches/mruby-expose-index-
# bodies.patch): BC2CPP_MRUBY_FULL, or one built here with rake (BC2CPP_FULL_BUILD_DIR keeps it). Skips without g++ / rake.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_integer_tag_else_run_check.rb

require_relative 'bc2cpp_fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
abort 'SKIP: no g++' unless runtime.compiler?
build = runtime.full_or_build
abort 'SKIP: no full-core build (set BC2CPP_MRUBY_FULL or install rake)' unless build

# Keys: fixnums on both sides of the index range, out-of-range counts, Floats, nil, Strings, Ranges (including reversed
# and out-of-bounds ones), and NaN. Receivers are literal Arrays, so each call site's receiver is exactly Array.
SOURCE = <<~RUBY
  $keys = [0, 1, -1, 2, 3, -3, 4, 9, 2 ** 40, -(2 ** 40), 1.5, nil, "s", 0..1, 1..2, -2..-1, 5...2, 0..9, 0.0 / 0.0]
  class Probe
    def get(i)
      a = [1, 2, 3]
      a[i]
    end

    def put(i, v)
      a = [1, 2, 3]
      a[i] = v
      a
    end
  end
RUBY

SCENARIO = <<~'CPP'
  #include <cstring>
  #include <string>
  struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[2]; };
  static mrb_value call_body(mrb_state* M, void* ud) {
    Call* c = (Call*)ud;
    return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
  }
  static std::string describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = mrb_funcall(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s)) + " (" + mrb_obj_classname(M, v) + ")";
  }
  static void row(mrb_state* M, const char* meth, mrb_value key, mrb_int argc) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    Call c = { probe, mrb_intern_cstr(M, meth), argc, {} };
    c.argv[0] = key;
    c.argv[1] = mrb_fixnum_value(9);
    int ai = mrb_gc_arena_save(M);
    mrb_bool raised = FALSE;
    mrb_value got = mrb_protect_error(M, call_body, &c, &raised);
    std::string text = describe(M, got, raised);
    std::printf("%s %s => %s\n", meth, mrb_obj_classname(M, key), text.c_str());
    mrb_gc_arena_restore(M, ai);
  }
  static int scenario(mrb_state* M) {
    mrb_value keys = mrb_gv_get(M, mrb_intern_lit(M, "$keys"));
    for (mrb_int j = 0; j < RARRAY_LEN(keys); ++j) row(M, "get", RARRAY_PTR(keys)[j], 1);
    for (mrb_int j = 0; j < RARRAY_LEN(keys); ++j) row(M, "put", RARRAY_PTR(keys)[j], 2);
    std::puts("end");
    return 0;
  }
CPP

check.call('the fixture-runtime helper is loaded and the core is built', build.is_a?(String))
Dir.mktmpdir do |dir|
  _code, err = runtime.generate(SOURCE, dir, closed: true, only_owners: %w[Probe])
  check.call('the positive fixture emits the direct calls',
             err[/integer-tag else.*?direct (\d+)/, 1].to_i.positive?)
  built, output = runtime.run(dir, err, %w[Probe], SCENARIO, build: build, full: true)
  check.call('the fixture compiles and runs against real mruby', built)
  puts output.to_s.lines.last(25).join unless built
  next unless built

  sections = runtime.sections(output)
  strip = ->(lines) { lines.to_a.reject { |l| l.start_with?('  ') } }
  interpreted = strip.call(sections['interpreted'])
  compiled = strip.call(sections['compiled'])
  check.call('both runs finish', interpreted.last == 'end' && compiled.last == 'end')
  check.call("the grid is large (#{interpreted.size} answers)", interpreted.size > 30)
  same = interpreted == compiled
  check.call('every answer is the interpreter\'s: value, class, exception class and message', same)
  interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each do |a, b|
    puts "    interpreted: #{a}\n    compiled:    #{b}"
  end
  check.call('the grid reaches exceptions', interpreted.count { |l| l.include?('raised') } > 5)
  check.call('a Range key is sliced (get 0..1 => [1, 2])',
             interpreted.any? { |l| l.start_with?('get Range => [1, 2]') } &&
             compiled.any? { |l| l.start_with?('get Range => [1, 2]') })
end

puts failures.empty? ? 'PASS' : "FAILED: #{failures.size}"
exit(failures.empty? ? 0 : 1)
