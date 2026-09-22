#!/usr/bin/env ruby
# encoding: UTF-8
# Checks for three compiled-send fast paths found from executed-funcall counts on
# the desktop RPGMAKER_BC2CPP build (RPG2k map scene):
#
#   LONE_ACCESSOR_CHAIN / EMBEDDED_ACCESSOR_CHAIN  a name whose only definition is
#       an attr_reader (`code`/`indent` on LCF::EventCommand) is an exact-class
#       guarded chain with the funcall fallback; an embedded ivar's accessor calls
#       the synthesized struct reader, never mrb_iv_get (which would read nil).
#   INDEX_CHAIN      the untyped `x[i]` tail goes through the same chain.
#   INTEGER_LSHIFT   `a << b` on two immediate Integers uses mrb_num_shift and
#       agrees with Integer#<< (compared on a real mruby core); overflow and
#       MRB_INT_MIN keep the ordinary dispatch.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

root = File.expand_path('..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def fixture(source, name, natives: [])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    c_dump, disasm = run_mrbc(path, "bc2cpp_#{name}", dir)
    ireps, root_label = parse_c_dump(c_dump, "bc2cpp_#{name}")
    order = dfs_order(ireps, root_label)
    blocks, block_files, block_catches = parse_disasm_blocks(disasm)
    merge!(ireps, order, blocks, block_files, block_catches)
    registry = build_registry(ireps, root_label)[0]
    natives.each do |op|
      registry[op] = [MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)] + Array(registry[op])
    end
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    yield gen, registry
  end
end

ACCESSOR = <<~'RUBY'
  class Command
    attr_reader :code
    attr_accessor :label
  end
  class Reader
    def read(cmd); cmd.code; end
    def write(cmd, v); cmd.label = v; end
  end
RUBY

fixture(ACCESSOR, 'lone_accessor') do |gen, registry|
  method = registry.fetch('read').find { |d| d.owner == 'Reader' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('a lone attr_reader is an exact-class chain, not a bare funcall',
             code.include?('POLY_SMALL_N :code -> Command') &&
               code.match?(/if \(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\) \{\n\s+r\d+ = mrb_iv_get\(M, r\d+, mrb_intern_cstr\(M, "@code"\)\);/))
  check.call('any other receiver class still reaches the funcall fallback', code.match?(/\} else \{\n\s+r\d+ = mrb_funcall\(M, r\d+, "code", 0\);/))

  # An embedded ivar's accessor is the synthesized struct reader.
  gen.instance_variable_get(:@synthesize_accessor_for) << ['Command', 'code', :reader]
  embedded = gen.compile_method(method.irep).fetch(:code)
  check.call('an embedded accessor calls the synthesized struct reader',
             embedded.include?('r') && embedded.match?(/r\d+ = Command_code_impl\(M, r\d+\);/) && !embedded.include?('"@code"'))
  wmethod = registry.fetch('write').find { |d| d.owner == 'Reader' }
  gen.instance_variable_get(:@synthesize_accessor_for) << ['Command', 'label', :writer]
  wcode = gen.compile_method(wmethod.irep).fetch(:code)
  check.call('an embedded writer calls the synthesized struct writer', wcode.match?(/r\d+ = Command_label_eq_impl\(M, r\d+, r\d+\);/))
end

INDEX = <<~'RUBY'
  class Vars
    def [](id); id; end
  end
  class Use
    def get(x, i); x[i]; end
  end
RUBY

fixture(INDEX, 'index_chain', natives: ['[]']) do |gen, registry|
  method = registry.fetch('get').find { |d| d.owner == 'Use' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('an untyped x[i] tail dispatches through the exact-class chain',
             code.include?('POLY_SMALL_N :[] -> Vars') && code.match?(/Vars_+impl\(M, r\d+, r\d+\)/))
  check.call('the exact Array/Hash/String arms are kept in front of it', code.include?('mrb_hash_get(M,') && code.include?('bc2cpp_ary_entry'))
end

SHIFT = <<~'RUBY'
  class Bits
    def shl(a, b); a << b; end
  end
RUBY

shift_code = nil
fixture(SHIFT, 'lshift', natives: ['<<']) do |gen, registry|
  method = registry.fetch('shl').find { |d| d.owner == 'Bits' }
  shift_code = gen.compile_method(method.irep).fetch(:code)
end
check.call('Integer << emits the mrb_num_shift arm with the fallback for overflow',
           shift_code.include?('INTEGER_LSHIFT :<<') && shift_code.include?('mrb_num_shift(M, bc2cpp_shl_v, bc2cpp_shl_w, &bc2cpp_shl_out)') &&
             shift_code.scan('mrb_funcall(M, r').size >= 2 && shift_code.include?('mrb_integer(r') && shift_code.include?('!= MRB_INT_MIN'))

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  snippet = shift_code[%r{// ARRAY_PUSH :<<.*?(?=\n  return r)}m] || shift_code[%r{// INTEGER_LSHIFT.*?(?=\n  return r)}m]
  recv, arg = snippet.scan(/mrb_integer_p\((r\d+)\)/).flatten.first(2)
  dest = recv.delete('r')
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'shl.cpp')
    File.write(source, <<~CPP)
      #include <mruby.h>
      #include <mruby/error.h>
      #include <mruby/array.h>
      #include <cstdio>
      #include <cstdarg>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);
      static int fallbacks = 0;
      // Count every trip to the ordinary dispatch the emitted snippet makes.
      #define mrb_funcall(M, s, name, argc, ...) (++fallbacks, (mrb_funcall)(M, s, name, argc, __VA_ARGS__))
      static mrb_value emitted(mrb_state* M, mrb_value in_recv, mrb_value in_arg) {
        mrb_value #{recv} = in_recv, #{arg} = in_arg;
        #{recv == "r#{dest}" ? '' : "mrb_value r#{dest} = mrb_nil_value();"}
        #{snippet}
        return r#{dest};
      }
      struct Args { mrb_value a, b; };
      static mrb_value body(mrb_state* M, void* ud) { Args* x = (Args*)ud; return emitted(M, x->a, x->b); }
      static mrb_value ref_body(mrb_state* M, void* ud) { Args* x = (Args*)ud; return (mrb_funcall)(M, x->a, "<<", 1, x->b); }
      int main() {
        mrb_state* M = mrb_open_core();
        mrb_int vals[] = { 0, 1, -1, 2, 5, -5, 1 << 20, -(1 << 20), MRB_INT_MAX, MRB_INT_MIN, MRB_INT_MAX / 2, MRB_INT_MIN / 2 };
        mrb_int shifts[] = { 0, 1, 2, 3, 15, 30, 31, 32, 62, 63, 64, 100, -1, -2, -31, -32, -63, -64, -100, MRB_INT_MAX, MRB_INT_MIN };
        int bad = 0, n = 0, fast = 0, fell = 0;
        for (mrb_int v : vals) for (mrb_int w : shifts) {
          Args args = { mrb_int_value(M, v), mrb_int_value(M, w) };
          mrb_bool e1 = FALSE, e2 = FALSE;
          fallbacks = 0;
          mrb_value got = mrb_protect_error(M, body, &args, &e1);
          int took_fallback = fallbacks;
          mrb_value want = mrb_protect_error(M, ref_body, &args, &e2);
          ++n; took_fallback ? ++fell : ++fast;
          bool same = e1 == e2 && (e1 || (mrb_integer_p(got) == mrb_integer_p(want) && (!mrb_integer_p(got) || mrb_integer(got) == mrb_integer(want))));
          if (!same) { ++bad; std::printf("MISMATCH %ld << %ld\\n", (long)v, (long)w); }
        }
        std::printf("compared %d shifts: %d fast, %d fallback, %d differ\\n", n, fast, fell, bad);
        mrb_close(M);
        return (bad || fast == 0 || fell == 0) ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'shl')
    built = system('g++', '-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted shift compiles against real mruby headers', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('the emitted shift agrees with Integer#<< on every value/count pair, on both the fast and fallback paths',
                 $?.success? && output.include?(' 0 differ'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp runtime devirt check: PASS'
else
  warn "bc2cpp runtime devirt check: #{failures.size} failure(s)"
  exit 1
end
