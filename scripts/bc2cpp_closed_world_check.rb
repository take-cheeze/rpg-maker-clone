#!/usr/bin/env ruby
# encoding: UTF-8
# Check CLOSED_WORLD (docs/adr/0210): on a single-format build a guard chain
# that provably lists every class answering a name ends in bc2cpp_nomethod
# instead of a by-name dispatch, and that raises exactly what the dispatch did.
#
#   - the build check refuses an open gem set, a non-single-format build and a
#     host that compiles a non-literal Ruby source; build_config.rb enables the
#     mode for the single-format builds only;
#   - generated code: a complete chain ends in bc2cpp_nomethod; an incomplete
#     chain, a core-defined name and a receiver that may be a method_missing
#     class keep the dispatch; without the switch nothing changes;
#   - run against the real mruby core: nil and a wrong-class receiver raise the
#     same NoMethodError (class, message, name, args) as the interpreter, and
#     `rescue` catches it; the kept sites still reach method_missing and
#     inherited methods.

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/compiled_gems'
require_relative '../tools/bc2cpp/nomethod_reviewed'

root = File.expand_path('..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The wio build's gem list (build_config.rb plus the gems it depends on).
core_gems = %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-numeric-ext mruby-range-ext mruby-fiber
               mruby-exit mruby-sprintf mruby-time mruby-bigint mruby-pack mruby-string-ext mruby-struct
               mruby-metaprog mruby-enumerator]
wio_gems = core_gems.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
wio_gems.merge!('hal-wio-io' => "#{root}/app/wio/hal-wio-io", 'mruby-math-wio' => "#{root}/app/wio/mruby-math-wio",
                'mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
%w[mruby-lcf mruby-lcf-compiled mruby-rgss mruby-rgss-compiled mruby-rpg2k mruby-rpg2k-compiled].each do |g|
  wio_gems[g] = "#{root}/#{g}"
end

# -- the build check ------------------------------------------------------------

check.call('the wio gem set is a closed world', bc2cpp_closed_world_violations('wio', wio_gems, root).empty?)
check.call('maix, with mruby-compiler, is one: its host only evaluates the literal probe',
           bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root).empty?)
{ 'mruby-eval' => 'mruby-eval', 'mruby-rpgxp' => 'an RGSS script host', 'mruby-mvjs' => 'mruby-mvjs' }.each do |gem, what|
  errors = bc2cpp_closed_world_violations('wio', wio_gems.merge(gem => 'x'), root)
  check.call("a build with #{what} is refused", errors.any? { |e| e.include?(gem) })
end
check.call('a desktop build is refused', !bc2cpp_closed_world_violations('host', wio_gems, root).empty?)
check.call('a gem list without the closed-world gems is refused',
           !bc2cpp_closed_world_violations('wio', wio_gems.except('mruby-rpg2k'), root).empty?)
Dir.mktmpdir do |dir|
  host = File.join(dir, 'main.cxx')
  File.write(host, "constexpr char kOk[] = \"\\\"alive\\\"\";\nvoid f(mrb_state* M, const char* s) {\n" \
                   "  mrb_load_string(M, kOk);\n  mrb_load_string(M, s);\n}\n")
  errors = bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root, host_srcs: [host])
  check.call('with mruby-compiler, a host compiling a runtime string is refused (and only that call)',
             errors.size == 1 && errors.first.include?('(s)'))
  File.write(host, "constexpr char kDef[] = \"def x; end\";\nvoid f(mrb_state* M) { mrb_load_string(M, kDef); }\n")
  errors = bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root, host_srcs: [host])
  check.call('a literal that defines a method is refused too', errors.size == 1)
end

config = File.read(File.join(root, 'build_config.rb'), encoding: 'UTF-8')
check.call('build_config.rb enables the mode for single-format builds only',
           config.match?(/closed_world = proc do\n\s+if single_format_only\n\s+enable_bc2cpp_closed_world\n/) &&
             BC2CPP_COMPILED_GEMS.keys.all? { |g| config.include?("#{g}\", &closed_world if bc2cpp") })
check.call('every compiled gem passes the mode through the checked env',
           BC2CPP_COMPILED_GEMS.keys.all? do |g|
             rake = File.read(File.join(root, g, 'mrbgem.rake'))
             rake.include?('extend Bc2cppClosedWorldOption') && rake.include?('.merge(bc2cpp_closed_world_env(spec, ')
           end)
spec = Struct.new(:name, :build) { include Bc2cppClosedWorldOption }
build = Struct.new(:name, :gems)
gem_list = ->(gems) { gems.map { |n, d| Struct.new(:name, :dir).new(n, d) } }
open_spec = spec.new('mruby-rpg2k-compiled', build.new('host', gem_list.call(wio_gems)))
check.call('a gem the build did not opt in passes no switch', bc2cpp_closed_world_env(open_spec, root) == {})
wio_spec = spec.new('mruby-rpg2k-compiled', build.new('wio', gem_list.call(wio_gems)))
wio_spec.enable_bc2cpp_closed_world
env = bc2cpp_closed_world_env(wio_spec, root)
check.call('an opted-in wio build passes the switch and its gem list',
           env['BC2CPP_CLOSED_WORLD'] == '1' && env['BC2CPP_BUILD_NAME'] == 'wio' &&
             Shellwords.split(env['BC2CPP_BUILD_GEMS']).include?("mruby-rpg2k=#{File.expand_path(root)}/mruby-rpg2k"))
bad_spec = spec.new('mruby-rpg2k-compiled', build.new('wio', gem_list.call(wio_gems.merge('mruby-eval' => 'x'))))
bad_spec.enable_bc2cpp_closed_world
raised = begin
  bc2cpp_closed_world_env(bad_spec, root)
  false
rescue RuntimeError => e
  e.message.include?('mruby-eval')
end
check.call('an opted-in build that is not closed fails loudly', raised)

# -- generated code -------------------------------------------------------------

# No method_missing class: every chain may be complete.
WORLD = <<~'RUBY'
  class CwPet
    def cw_speak; 1; end
    def cw_fetch(a, b); a + b; end
    def cw_bark; 10; end
    def size; 5; end
  end
  class CwRobot
    def cw_speak; 2; end
    def cw_fetch(a, b); a - b; end
    def size; 6; end
  end
  class CwDog
    def cw_bark; 20; end
  end
  # A mixin on the way keeps INHERITED_GUARD from listing CwPuppy, so the
  # chain does not cover every class that answers cw_bark.
  module CwTrick
  end
  class CwPuppy < CwDog
    include CwTrick
  end
  class CwOther
  end
  class CwCaller
    def talk(x); x.cw_speak; end
    def fetch(x); x.cw_fetch(1, 2); end
    def bark(x); x.cw_bark; end
    def measure(x); x.size; end
  end
RUBY

# A method_missing class: only a `self` receiver can be proven not to be one.
GHOST_WORLD = <<~'RUBY'
  class CwGhost
    def method_missing(name, *args); 42; end
  end
  class CwBase
    def cw_speak; 1; end
    def chat; cw_speak; end
  end
  class CwKid < CwBase
    def cw_speak; 3; end
  end
  class CwRobot
    def cw_speak; 2; end
  end
  class CwCaller
    def talk(x); x.cw_speak; end
  end
RUBY

# INHERITED_GUARD lists a plain subclass in the chain, which is then complete.
INHERIT_WORLD = <<~'RUBY'
  class CwWolf
    def cw_howl; 1; end
  end
  class CwWolfPup < CwWolf
  end
  class CwFox
    def cw_howl; 2; end
  end
  class CwCaller
    def howl(x); x.cw_howl; end
  end
RUBY

mrbc = ENV['MRBC'] || 'mrbc'
generate = lambda do |source, name, closed|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1' }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(wio_gems.map { |n, d| "#{n}=#{d}" }),
                 # The fixtures' dead sites are the point; NOMETHOD_REVIEWED gates real gems.
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    [out, err]
  end
end
# The body of one compiled method, from its _impl definition to the next function.
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

open_code, = generate.call(WORLD, 'cw_open', false)
closed_code, closed_err = generate.call(WORLD, 'cw_closed', true)
ghost_code, ghost_err = generate.call(GHOST_WORLD, 'cw_ghost', true)
inherit_code, = generate.call(INHERIT_WORLD, 'cw_inherit', true)

check.call('without the switch no fallback changes: no bc2cpp_nomethod, ancestry-aware owner lookup',
           !open_code.include?('bc2cpp_nomethod') && !open_code.include?('CLOSED_WORLD') &&
             body_of.call(open_code, 'CwCaller_talk').include?('bc2cpp_send(') &&
             open_code.include?('if (!mrb_const_defined(M, v, s)) return nullptr;'))
talk = body_of.call(closed_code, 'CwCaller_talk')
check.call('a complete chain (every definer, no subclass, no method_missing) ends in bc2cpp_nomethod',
           talk.include?('POLY_SMALL_N :cw_speak') && talk.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+\);/) &&
             !talk.include?('bc2cpp_send('))
check.call('its arguments are passed on (NoMethodError#args)',
           body_of.call(closed_code, 'CwCaller_fetch').match?(/bc2cpp_nomethod\(M, r\d+, \d+, 2, r\d+, r\d+\);/))
check.call('a chain missing an inheriting subclass keeps the dispatch',
           body_of.call(closed_code, 'CwCaller_bark').match?(%r{bc2cpp_send\([^;]*\); /\* CLOSED_WORLD kept: unlisted_class \*/}))
check.call('an inheriting subclass the chain lists (INHERITED_GUARD) completes it: bc2cpp_nomethod',
           body_of.call(inherit_code, 'CwCaller_howl').then do |howl|
             howl.include?('INHERITED_GUARD :cw_howl -- also CwWolfPup < CwWolf') &&
               howl.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+\);/) && !howl.include?('bc2cpp_send(')
           end)
check.call('a name mruby core defines keeps the dispatch',
           body_of.call(closed_code, 'CwCaller_measure').include?('CLOSED_WORLD kept: core_or_native'))
check.call('the guard names exactly the registry class (no lookup through ancestry)',
           closed_code.include?('if (!mrb_const_defined_at(M, v, s)) return nullptr;'))
check.call('the summary counts what was converted and why the rest was kept',
           closed_err.include?('== closed world fallbacks: 0 guards dropped, 2 bc2cpp_nomethod, 2 kept dispatching ==') &&
             closed_err.include?('KEPT unlisted_class: 1') && closed_err.include?('KEPT core_or_native: 1'))
check.call('a receiver that may be a method_missing instance keeps the dispatch',
           ghost_err.include?('method_missing classes: CwGhost') &&
             body_of.call(ghost_code, 'CwCaller_talk').include?('CLOSED_WORLD kept: method_missing_receiver'))
check.call('a self receiver in a class with no method_missing still converts',
           body_of.call(ghost_code, 'CwBase_chat').match?(/bc2cpp_nomethod\(M, self, \d+\);/))

# CLOSED_WORLD_SELF: a self call into an embedding owner nothing subclasses
# needs no guard at all; a subclass keeps the guard (and the dispatch).
require_relative '../tools/bc2cpp/bc2cpp'
COUNTER = <<~'RUBY'
  class CwCounter
    def initialize; @n = 0; end
    def bump; @n = @n + 1; end
    def twice; bump; bump; end
  end
RUBY
native, ruby = bc2cpp_closed_world_outside_srcs('wio', wio_gems, root)
[['no subclass', COUNTER, true], ['a subclass', "#{COUNTER}class CwCounterKid < CwCounter; end\n", false]].each do |what, src, dropped|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'counter.rb')
    File.write(path, src)
    c_dump, disasm = run_mrbc(path, 'bc2cpp_cw_counter', dir)
    ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_cw_counter')
    blocks, block_files, block_catches = parse_disasm_blocks(disasm)
    merge!(ireps, dfs_order(ireps, root_label), blocks, block_files, block_catches)
    registry, superclass_of, _c, included, prepended, unknown, _s, class_decls, walked = build_registry(ireps, root_label)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                            native_paths: native, ruby_paths: ruby)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown, closed_world: world)
    gen.instance_variable_get(:@ivar_layout)['CwCounter'] = { 'n' => :fixnum }
    code = gen.compile_method(registry.fetch('twice').find { |d| d.owner == 'CwCounter' }.irep).fetch(:code)
    ok = if dropped
           code.include?('CLOSED_WORLD_SELF :bump') && !code.include?('mrb_obj_class')
         else
           code.include?('MONO_EMBED_GUARD :bump') && code.include?('CLOSED_WORLD kept: unlisted_class')
         end
    check.call("a self call into an embedding owner with #{what} #{dropped ? 'drops' : 'keeps'} the guard", ok)
  end
end

# -- run against the real mruby core ---------------------------------------------

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |d| File.exist?(File.join(d, 'lib/libmruby_core.a')) && File.directory?(File.join(d, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  run = lambda do |code, ruby, defines, probes|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'gen.cpp'), code)
      harness = File.join(dir, 'harness.cpp')
      File.write(harness, <<~CPP)
        #include "gen.cpp"
        #include <mruby/compile.h>
        #include <cstdio>
        #include <cstdlib>
        extern "C" void mrb_init_mrblib(mrb_state*) {}
        static const char* str(mrb_state* M, mrb_value v) { return mrb_str_to_cstr(M, mrb_inspect(M, v)); }
        static void load(mrb_state* M, const char* ruby) {
          mrb_load_string(M, ruby);
          if (M->exc) { std::printf("uncaught %s\\n", str(M, mrb_obj_value(M->exc))); std::exit(1); }
        }
        int main() {
          mrb_state* M = mrb_open_core();
          // NameError/NoMethodError live in mruby's mrblib, which the core build lacks.
          load(M, #{File.read(File.join(root, '3rd/mruby/mrblib/10error.rb')).inspect});
          load(M, #{ruby.inspect});
          #{defines}
          #{probes}
          mrb_close(M);
          return 0;
        }
      CPP
      binary = File.join(dir, 'harness')
      built = system('g++', '-std=c++17', '-w', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                     "-I#{dir}", "-I#{core}/include", "-I#{root}/3rd/mruby/include", harness,
                     "#{core}/lib/libmruby_core.a", '-o', binary)
      built ? IO.popen(binary, err: %i[child out], &:read) : nil
    end
  end
  define = ->(klass, meth, argc) { "mrb_define_method(M, mrb_class_get(M, \"#{klass}\"), \"#{meth}\", #{klass}_#{meth}, MRB_ARGS_REQ(#{argc}));" }

  # Each case runs the compiled method and the interpreter on the same
  # receiver; the harness compares both exceptions' class, message, name and
  # args. (mrb_open_core has no mrblib, so no iterators here.)
  compare = <<~RUBY
    $cases = []
    def cw_case(r)
      a = begin; CwCaller.new.talk(r); rescue NoMethodError => e; e; end
      b = begin; r.cw_speak; rescue NoMethodError => e; e; end
      $cases << [a, b]
      a = begin; CwCaller.new.fetch(r); rescue NoMethodError => e; e; end
      b = begin; r.cw_fetch(1, 2); rescue NoMethodError => e; e; end
      $cases << [a, b]
    end
    cw_case(nil)
    cw_case(CwOther.new)
    cw_case(7)
    $rescued = begin; CwCaller.new.talk(nil); :missed; rescue StandardError; :rescued; end
    $values = [CwCaller.new.talk(CwPet.new), CwCaller.new.talk(CwRobot.new), CwCaller.new.fetch(CwPet.new),
               CwCaller.new.bark(CwPuppy.new), CwCaller.new.measure(CwRobot.new)]
  RUBY
  probes = <<~'CPP'
    mrb_value cases = mrb_gv_get(M, mrb_intern_lit(M, "$cases"));
    int same = 0, raised = 0;
    for (mrb_int i = 0; i < RARRAY_LEN(cases); ++i) {
      mrb_value pair = mrb_ary_ref(M, cases, i);
      mrb_value a = mrb_ary_ref(M, pair, 0), b = mrb_ary_ref(M, pair, 1);
      if (!mrb_exception_p(a) || !mrb_exception_p(b)) continue;
      ++raised;
      mrb_sym name = mrb_intern_lit(M, "@name"), args = mrb_intern_lit(M, "@args");
      bool eq = mrb_obj_class(M, a) == mrb_obj_class(M, b) &&
                mrb_equal(M, mrb_funcall(M, a, "message", 0), mrb_funcall(M, b, "message", 0)) &&
                mrb_equal(M, mrb_iv_get(M, a, name), mrb_iv_get(M, b, name)) &&
                mrb_equal(M, mrb_iv_get(M, a, args), mrb_iv_get(M, b, args));
      if (eq) ++same; else std::printf("differ: %s vs %s\n", str(M, a), str(M, b));
    }
    std::printf("raised %d of %d, identical %d\n", raised, (int)RARRAY_LEN(cases), same);
    std::printf("rescued %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$rescued"))));
    std::printf("values %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));
  CPP
  defines = [define.call('CwCaller', 'talk', 1), define.call('CwCaller', 'fetch', 1), define.call('CwCaller', 'bark', 1),
             define.call('CwCaller', 'measure', 1)].join("\n")
  output = run.call(closed_code, WORLD, "#{defines}\nload(M, #{compare.inspect});", probes)
  check.call('the closed-world code compiles and runs against the real mruby core', !output.nil?)
  if output
    puts output.lines.map { |l| "  #{l}" }.join
    check.call('nil, a wrong-class object and an Integer raise the identical NoMethodError (class, message, name, args)',
               output.include?('raised 6 of 6, identical 6'))
    check.call('rescue catches it', output.include?('rescued :rescued'))
    check.call('listed receivers, an inherited method and a core name still answer', output.include?('values [1, 2, 3, 20, 6]'))
  end

  ghost_ruby = <<~RUBY
    $values = [CwCaller.new.talk(CwGhost.new), CwKid.new.chat, CwBase.new.chat, CwCaller.new.talk(CwRobot.new)]
  RUBY
  ghost_defines = [define.call('CwCaller', 'talk', 1), define.call('CwBase', 'chat', 0)].join("\n")
  ghost_probe = 'std::printf("values %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));'
  output = run.call(ghost_code, GHOST_WORLD, "#{ghost_defines}\nload(M, #{ghost_ruby.inspect});", ghost_probe)
  check.call('the method_missing world compiles and runs', !output.nil?)
  if output
    puts output.lines.map { |l| "  #{l}" }.join
    check.call('a kept site still reaches method_missing; the converted self site still dispatches by class',
               output.include?('values [42, 3, 1, 2]'))
  end
end

if failures.empty?
  puts 'bc2cpp closed world check: PASS'
else
  warn "bc2cpp closed world check: #{failures.size} failure(s)"
  exit 1
end
