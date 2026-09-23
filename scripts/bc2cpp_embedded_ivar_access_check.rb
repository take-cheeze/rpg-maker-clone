#!/usr/bin/env ruby
# encoding: UTF-8
# Check IVAR_ACCESS (tools/bc2cpp/bc2cpp.rb's ivar_get_code/ivar_set_code): an
# embedded ivar lives in the RData struct, so generated code must never reach it
# through iv_tbl (mrb_iv_get reads nil, mrb_iv_set writes a table nothing reads).
#
# 1. A fixture is generated, compiled against real mruby and run: a foreign
#    `purse.gold` read/write and a self-implicit `gold` must see the struct.
#    Needs BC2CPP_MRUBY_CORE (libmruby_core.a + include/) and g++; skipped
#    without them.
# 2. The three compiled gems are generated as their mrbgem.rake does, and every
#    mrb_iv_* call whose receiver class (exact-class guard, or self in that
#    class's own method) embeds the ivar is reported. Must be zero.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp_embedded_ivar_access_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'
require_relative '../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('..', __dir__)
BC2CPP =File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def run_bc2cpp(env, srcs, out_path)
  cmd = "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} #{srcs.map(&:shellescape).join(' ')} > #{out_path.shellescape}"
  _out, err, status = Open3.capture3(env.merge('MRBC' => MRBC, 'SKIP_UNSUPPORTED' => '1'), cmd)
  abort "bc2cpp.rb failed:\n#{err[-2000..]}" unless status.success?
  err
end

# Every mrb_iv_* call in generated code as [line index, op, receiver, ivar],
# resolving the SYMBOL_CACHE table (bc2cpp_sym(M, i)).
def iv_tbl_calls(code)
  symbols = code[/bc2cpp_sym_names\[\d+\] = \{\n(.*?)\n\};/m, 1].to_s.scan(/^  "((?:[^"\\]|\\.)*)",?$/).flatten
  code.lines.each_with_index.filter_map do |line, i|
    m = line.match(/mrb_(?:obj_)?iv_(get|set|defined|remove)\(M, ([^,]+), (?:bc2cpp_sym\(M, (\d+)\)|mrb_intern_(?:cstr|lit)\(M, "([^"]+)"\))/)
    m && [i, m[1], m[2], (m[3] ? symbols[m[3].to_i] : m[4]).to_s.delete_prefix('@')]
  end
end

FIXTURE = <<~'RUBY'
  class Purse
    attr_accessor :gold

    # bc2cpp: (fixnum)
    def initialize(gold)
      @gold = gold
    end

    def total
      @gold
    end

    def doubled
      gold * 2
    end
  end

  class Shop
    def read_gold
      purse = Purse.new(7)
      purse.gold
    end

    def write_gold
      purse = Purse.new(1)
      purse.gold = 9
      purse.total
    end

    def doubled_gold
      Purse.new(21).doubled
    end
  end
RUBY

puts '-- embedding gate and self-class-unknown bodies'
LAYOUT_FIXTURE = <<~'RUBY'
  class Base
    # bc2cpp: (fixnum)
    def initialize(v); @v = v; end
    def v2; @v; end
  end
  class Sub < Base
    def peek; @v; end
  end
  class Solo
    # bc2cpp: (fixnum)
    def initialize(w); @w = w; end
    def w2; @w; end
  end
RUBY
Dir.mktmpdir do |dir|
  path = File.join(dir, 'layout.rb')
  File.write(path, LAYOUT_FIXTURE)
  c_dump, disasm = run_mrbc(path, 'bc2cpp_layout', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_layout')
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, dfs_order(ireps, root_label), blocks, block_files, block_catches)
  registry, superclass_of = build_registry(ireps, root_label)
  ivar_layout = IvarLayout.analyze(ireps, registry, {}, Annotations.extract(ireps, registry))
  gen = CodeGen.new(ireps, registry, ivar_layout, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
  check.call('an ivar a subclass method also touches is never embedded (its GETIV would read iv_tbl)',
             gen.embed_type('Base', 'v').nil? && gen.embed_type('Solo', 'w') == :fixnum)
  w2 = registry.fetch('w2').find { |d| d.owner == 'Solo' }
  irep = ireps.fetch(w2.irep)
  getiv = irep.instructions.index { |insn| insn.op == 'GETIV' }
  gen.instance_variable_set(:@self_class_unknown, true)
  unknown = gen.compile_insn(irep.instructions[getiv], irep, w2, getiv)
  gen.instance_variable_set(:@self_class_unknown, false)
  known = gen.compile_insn(irep.instructions[getiv], irep, w2, getiv)
  check.call('GETIV of an embedded name refuses to compile where self\'s class is unknown (runtime-def/EXEC body)',
             unknown.include?('#error') && known.include?('DATA_PTR(self))->w'))
end

puts '-- fixture (foreign and self accessor reads of an embedded ivar)'
core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
Dir.mktmpdir do |dir|
  src = File.join(dir, 'purse.rb')
  File.write(src, FIXTURE)
  gen = File.join(dir, 'purse_gen.cpp')
  err = run_bc2cpp({ 'OUT_SYMBOL' => 'purse', 'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1' }, [src], gen)
  code = File.read(gen)
  check.call('Purse#@gold is embedded', code.include?('struct Purse_ivars {'))
  check.call('no iv_tbl access to @gold anywhere', iv_tbl_calls(code).none? { |*, ivar| ivar == 'gold' })
  check.call('the foreign read and write use the synthesized accessor',
             code.match?(/r\d+ = Purse_gold_impl\(M, r\d+\);/) && code.match?(/r\d+ = Purse_gold_eq_impl\(M, r\d+, r\d+\);/))

  if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, extra|
      fn = extra.include?('[private') ? 'mrb_define_private_method' : 'mrb_define_method'
      "  #{fn}(M, mrb_class_get(M, #{owner.dump}), #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include "purse_gen.cpp"
      #include <mruby/irep.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static int failed = 0;
      static void expect(mrb_state* M, const char* what, mrb_int want) {
        mrb_value got = mrb_funcall(M, mrb_obj_new(M, mrb_class_get(M, "Shop"), 0, nullptr), what, 0);
        if (M->exc) { std::printf("  Shop#%s -> raised (want %ld)\\n", what, (long)want); M->exc = nullptr; ++failed; return; }
        bool ok = mrb_integer_p(got) && mrb_integer(got) == want;
        std::printf("  Shop#%s -> %s (want %ld)\\n", what, ok ? "ok" : "WRONG", (long)want);
        failed += !ok;
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        bc2cpp_set_instance_tts(M);
      #{registrations.join("\n")}
        expect(M, "read_gold", 7);
        expect(M, "write_gold", 9);
        expect(M, "doubled_gold", 42);
        mrb_close(M);
        return failed ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'purse')
    built = system('g++', '-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'purse.mrb')], err: %i[child out], &:read)
      puts output
      check.call('compiled accessors read and write the embedded struct on real mruby', $?.success?)
    end
  end
end

# The class a mrb_iv_* call is made on: the exact-class guard just above it, or
# self in the method the enclosing function was compiled from.
def site_class(lines, index, recv, func, slot_paths, by_sanitized)
  # The nearest guard line; its first compare names the owner (INHERITED_GUARD
  # appends subclasses that share the owner's accessor after it).
  guard_re = /bc2cpp_owner_class_(\d+)\(M\) == (?:mrb_obj_class\(M, #{Regexp.escape(recv)}\)|bc2cpp_recv_class)/
  guard = lines[[index - 3, 0].max..index].reverse.lazy.filter_map { |line| line[guard_re, 1] }.first
  return slot_paths.fetch(guard.to_i) if guard
  return nil unless recv == 'self' && func

  prefix = by_sanitized.keys.select { |s| func.start_with?("#{s}_") }.max_by(&:size)
  prefix && by_sanitized[prefix]
end

puts '-- compiled gems (iv_tbl access on an embedded ivar)'
srcs = closed_world_mrblib_srcs(ROOT)
native = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
foreign = foreign_mrblib_srcs(ROOT)
Dir.mktmpdir do |dir|
  results = BC2CPP_COMPILED_GEMS.map do |name, gem|
    Thread.new do
      others = BC2CPP_COMPILED_GEMS.reject { |n, _| n == name }
      env = { 'OUT_SYMBOL' => gem[:out_symbol], 'OUT_DIR' => dir, 'ONLY_OWNERS' => gem[:owners].join(','),
              'OTHER_OWNERS' => others.values.flat_map { |x| x[:owners] }.join(','),
              'NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign) }
      path = File.join(dir, "#{gem[:out_symbol]}_gen.cpp")
      err = run_bc2cpp(env, srcs, path)
      [name, File.read(path), err]
    end
  end.map(&:value)

  owners = results.flat_map { |_, _, err| err.scan(/\(\d+ defs?: ([^)]*)\)/).flatten.flat_map { |s| s.split(', ') } }.uniq
  by_sanitized = owners.to_h { |o| [o.gsub(/[^a-zA-Z0-9_]/, '_'), o] }
  embedded = {}
  results.each do |_, code, _|
    code.scan(/^struct (\w+)_ivars \{\n(.*?)^\};/m) do |sname, body|
      embedded[by_sanitized.fetch(sname)] = body.scan(/ (\w+);$/).flatten
    end
  end
  check.call("found the embedded layouts (#{embedded.sum { |_, v| v.size }} ivars in #{embedded.size} classes)",
             embedded.size >= 10)

  sites = []
  results.each do |name, code, _|
    slot_paths = code.scan(/path\[\] = \{([^}]*)\};\n\s*c = bc2cpp_owner_class_slots\[(\d+)\]/)
                     .to_h { |path, slot| [slot.to_i, path.scan(/"([^"]+)"/).flatten.join('::')] }
    lines = code.lines
    # The generated function each line belongs to.
    func = nil
    funcs = lines.map { |line| func = line[/^(?:static )?(?:inline )?mrb_value (\w+)\(/, 1] || func }
    iv_tbl_calls(code).each do |i, op, recv, ivar|
      next unless embedded.any? { |_, ivars| ivars.include?(ivar) }

      klass = site_class(lines, i, recv, funcs[i], slot_paths, by_sanitized)
      if klass.nil? && recv != 'self'
        sites << "#{name}:#{i + 1} mrb_iv_#{op} on an unguarded #{recv} for @#{ivar} (some class embeds it) in #{funcs[i]}"
      elsif klass && embedded[klass]&.include?(ivar)
        sites << "#{name}:#{i + 1} mrb_iv_#{op} #{klass}#@#{ivar} in #{funcs[i]}"
      end
    end
  end
  sites.first(80).each { |s| puts "    #{s}" }
  check.call("no iv_tbl access to an embedded ivar in the generated gems (#{sites.size} found)", sites.empty?)
end

if failures.empty?
  puts 'bc2cpp embedded ivar access check: PASS'
else
  warn "bc2cpp embedded ivar access check: #{failures.size} failure(s)"
  exit 1
end
