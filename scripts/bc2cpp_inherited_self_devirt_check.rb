#!/usr/bin/env ruby
# encoding: UTF-8
# Checks two call-site devirtualizations in tools/bc2cpp/bc2cpp.rb (docs/adr/0207):
#
#   SINGLETON_LEXICAL_SELF  an implicit-self call inside `def self.x` of a module
#       (or of a class nothing subclasses) calls that singleton's own def directly.
#   INHERITED_GUARD  a POLY_SMALL_N branch for owner T also accepts every
#       closed-world subclass whose lookup of the name provably ends at T.
#
# 1. Fixtures pin each refusal: a subclassed class, a prepend onto the singleton,
#    a duplicate singleton def, an override or mixin between subclass and owner,
#    an alias_method of the name, and a native definition.
# 2. A fixture is generated, compiled against real mruby and run: every call must
#    return what the interpreter would, and the devirtualized calls must not
#    reach mrb_funcall/mrb_funcall_id. Needs BC2CPP_MRUBY_CORE (libmruby_core.a + include/)
#    and g++; skipped without them.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp_inherited_self_devirt_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'
require_relative '../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

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
    blocks, block_files, block_catches = parse_disasm_blocks(disasm)
    merge!(ireps, dfs_order(ireps, root_label), blocks, block_files, block_catches)
    registry, superclass_of, _containers, included, prepended, unknown_mixins = build_registry(ireps, root_label)
    natives.each do |op|
      registry[op] = [MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)] + Array(registry[op])
    end
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown_mixins)
    yield(->(owner, meth) { gen.compile_method(registry.fetch(meth).find { |d| d.owner == owner }.irep).fetch(:code) })
  end
end

SINGLETON = <<~'RUBY'
  module Util
    def self.clamp(v, lo, hi)
      v < lo ? lo : (v > hi ? hi : v)
    end

    def self.offset(pos, screen, map)
      max = map - screen
      max = 0 if max < 0
      clamp(pos - screen / 2, 0, max)
    end
  end

  class Viewer
    def clamp(v, lo, hi); 99; end
  end
RUBY

puts '-- SINGLETON_LEXICAL_SELF'
fixture(SINGLETON, 'singleton_self') do |code_of|
  check.call('an implicit-self call in a module singleton method is a direct call',
             code_of.call('Util.singleton', 'offset').match?(/LEXICAL_SELF :clamp -> Util\.singleton#clamp.*\n\s+r\d+ = Util_singleton_clamp_impl\(M, self, /))
end
[['a subclassed class', "class Shape\n  def self.clamp(v, lo, hi); v; end\n  def self.offset(a); clamp(a, 0, 1); end\nend\nclass Circle < Shape; end\n", 'Shape'],
 ['a prepend onto the singleton', "module Hook; end\nmodule Pre\n  class << self; prepend Hook; end\n  def self.clamp(v, lo, hi); v; end\n  def self.offset(a); clamp(a, 0, 1); end\nend\n", 'Pre'],
 ['a duplicate singleton def', "module Dup\n  def self.clamp(v, lo, hi); v; end\n  def self.clamp(v, lo, hi); lo; end\n  def self.offset(a); clamp(a, 0, 1); end\nend\n", 'Dup']].each do |what, source, owner|
  fixture(source + "class Viewer\n  def clamp(v, lo, hi); 99; end\nend\n", 'singleton_self_refused') do |code_of|
    check.call("#{what} keeps the implicit-self call dynamic", !code_of.call("#{owner}.singleton", 'offset').include?('LEXICAL_SELF'))
  end
end

INHERITED = <<~'RUBY'
  module Tagged
    def label; "tagged"; end
  end

  class Base
    attr_reader :db
    def initialize; @db = 7; end
    def label; "base"; end
  end

  class Other
    attr_reader :db
    def initialize; @db = 1; end
    def label; "other"; end
  end

  class Mid < Base; end
  class Leaf < Mid; end

  class Override < Base
    def label; "override"; end
  end

  class Mixed < Base
    include Tagged
  end

  class Probe
    def run_label(x); x.label; end
    def run_db(x); x.db; end
  end
RUBY

INHERITED_LABEL_OWNERS = 'Leaf < Base, Mid < Base'

puts '-- INHERITED_GUARD'
fixture(INHERITED, 'inherited') do |code_of|
  label = code_of.call('Probe', 'run_label')
  check.call("Base#label's branch also accepts exactly #{INHERITED_LABEL_OWNERS}",
             label.include?("INHERITED_GUARD :label -- also #{INHERITED_LABEL_OWNERS}\n"))
  check.call('the receiver class is read once and the funcall fallback is kept',
             label.scan('mrb_obj_class(M, ').size == 1 && label.match?(/\} else \{\n\s+r\d+ = mrb_funcall\(M, r\d+, "label", 0\);/))
  check.call('an inherited accessor joins the same branch, and any mixin on the way declines',
             code_of.call('Probe', 'run_db').include?("INHERITED_GUARD :db -- also Leaf < Base, Mid < Base, Override < Base\n"))
end
fixture(INHERITED + "class Leaf\n  alias_method :label, :to_s\nend\n", 'inherited_alias') do |code_of|
  check.call('an alias_method of the name anywhere keeps subclasses on the fallback',
             !code_of.call('Probe', 'run_label').include?('INHERITED_GUARD'))
end
fixture(INHERITED, 'inherited_native', natives: ['label']) do |code_of|
  check.call('a native definition of the name keeps subclasses on the fallback',
             !code_of.call('Probe', 'run_label').include?('INHERITED_GUARD'))
end

RUNTIME = SINGLETON + INHERITED + <<~'RUBY'
  class Probe
    def cam; Util.offset(100, 40, 60); end
  end
RUBY

# [Probe method, receiver class (nil: none), expected, dynamic dispatches allowed]
CASES = [
  ['cam', nil, 20, 0],
  ['run_label', 'Base', 'base', 0],
  ['run_label', 'Leaf', 'base', 0],
  ['run_label', 'Mid', 'base', 0],
  ['run_label', 'Override', 'override', 0],
  ['run_label', 'Other', 'other', 0],
  ['run_label', 'Mixed', 'tagged', 1],
  ['run_db', 'Leaf', 7, 0],
  ['run_db', 'Mixed', 7, 1],
  ['run_db', 'Other', 1, 0]
].freeze

puts '-- fixture on real mruby'
core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    src = File.join(dir, 'fixture.rb')
    File.write(src, RUNTIME)
    gen = File.join(dir, 'fixture_gen.cpp')
    _out, err, status = Open3.capture3({ 'MRBC' => MRBC, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'fixture',
                                         'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1',
                                         'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby")) },
                                       "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} #{src.shellescape} > #{gen.shellescape}")
    abort "bc2cpp.rb failed:\n#{err[-2000..]}" unless status.success?

    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, extra|
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{owner.delete_suffix('.singleton').dump})))"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    calls = CASES.map do |meth, recv, want, allowed|
      arg = recv ? "mrb_obj_new(M, mrb_class_get(M, #{recv.dump}), 0, nullptr)" : 'mrb_nil_value()'
      argc = recv ? 1 : 0
      want_expr = want.is_a?(String) ? "mrb_str_new_cstr(M, #{want.dump})" : "mrb_fixnum_value(#{want})"
      "  expect(M, #{meth.dump}, #{arg}, #{argc}, #{want_expr}, #{allowed}, #{"#{meth}(#{recv})".dump});"
    end
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      static int fallbacks = 0;
      // Count every dynamic dispatch the compiled bodies make.
      #define mrb_funcall_id(M, ...) (++fallbacks, (mrb_funcall_id)(M, __VA_ARGS__))
      #define mrb_funcall(M, ...) (++fallbacks, (mrb_funcall)(M, __VA_ARGS__))
      #include "fixture_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static int failed = 0;
      static void expect(mrb_state* M, const char* meth, mrb_value arg, int argc, mrb_value want, int allowed, const char* what) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        fallbacks = 0;
        mrb_value got = (mrb_funcall)(M, probe, meth, argc, arg);
        if (M->exc) { std::printf("  %s -> raised\\n", what); M->exc = nullptr; ++failed; return; }
        bool ok = mrb_equal(M, got, want) && fallbacks <= allowed;
        std::printf("  %s -> %s (%d dynamic dispatch, %d allowed)\\n", what, ok ? "ok" : "WRONG", fallbacks, allowed);
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
      #{calls.join("\n")}
        mrb_close(M);
        return failed ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'fixture')
    built = system('g++', '-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'fixture.mrb')], err: %i[child out], &:read)
      puts output
      check.call('every call returns the interpreter\'s answer without an extra dynamic dispatch', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp inherited/self devirt check: PASS'
else
  warn "bc2cpp inherited/self devirt check: #{failures.size} failure(s)"
  exit 1
end
