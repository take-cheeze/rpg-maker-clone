#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check DOUBLE_DEFINITIONS (tools/bc2cpp/double_definitions.rb, docs/adr/0319): a class that defines one
# name twice runs its LAST definition in the interpreter, and the compiled program must too. The forms
# (scripts/bc2cpp_double_definition_fixture.rb): attr_* then def and the reverse, attr_* and def around a
# define_method, def then def, three defs, a reopened class, alias and alias_method over a def, an alias
# that keeps the earlier body, a conditional later def, a call between the two definitions, a live
# definition that raises, private after two definitions, super into a doubly defined method, `def self.m`
# twice and through `class << self`, module_function over a redefined def, and an instance method whose C++
# spelling equals a singleton method's.
#
#   1. unit       the registry reduction on mrbc-compiled sources;
#   2. generated  each form compiled alone: one definition per (owner, name), distinct symbols, the last
#                 definition resolved, the withdrawal when no last definition can be proven;
#   3. run        the compiled fixture against the interpreter on a full-core, a core-only and a 32-bit
#                 mrb_int build (BC2CPP_BLOCK_DIRECT_ENTRY=0 on the last: ADR 0271 keeps a block's entry as an
#                 address in a 32-bit slot, which this 64-bit host truncates). The fixture is loaded by the
#                 harness gem and the same binary runs once with the generated registration and once without
#                 it (DD_INTERPRETED=1), so the two outputs differ only in which bodies run.
#
# DD_MODE: all (default), static (unit and generated, no mruby build), unit, generated, run. DD_TOOL_DIR names a
# copy of tools/bc2cpp placed inside the repository (scripts/bc2cpp_double_definition_mutation_check.rb).
# DD_FORMS: comma-separated form names, to run a subset. DD_DIR: keep the build directories there.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp_double_definition_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative 'bc2cpp_cxx'

ROOT = File.expand_path('..', __dir__)
TOOL_DIR = ENV['DD_TOOL_DIR'] || File.join(ROOT, 'tools/bc2cpp')
MRBC_PATH = ENV['MRBC'] || 'mrbc'
MODE = ENV['DD_MODE'] || 'all'
MRUBY = File.join(ROOT, '3rd/mruby')
ENV['MRBC'] = MRBC_PATH
require File.join(TOOL_DIR, 'bc2cpp')
require File.join(TOOL_DIR, 'compiled_gems')
require File.join(TOOL_DIR, 'nomethod_reviewed')
require File.join(TOOL_DIR, 'nomethod_reviewed_probe')
require_relative 'bc2cpp_double_definition_fixture'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

DD = DoubleDefinitionFixture
selected = ENV['DD_FORMS'] ? ENV['DD_FORMS'].split(',') : nil
FORMS = selected ? DD::FORMS.select { |f| selected.include?(f.name) } : DD::FORMS
have_mrbc = tool?(MRBC_PATH)
run_unit = %w[all static unit].include?(MODE)
run_generated = %w[all static generated].include?(MODE)
run_behaviour = %w[all run].include?(MODE)

# -- 1. unit -------------------------------------------------------------------------------------

BUILD_GEMS = NomethodReviewedProbe.wio_gems(ROOT)
NATIVE_SRCS = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)

# [stdout, stderr] of bc2cpp for +source+, compiled with the closed world of the wio build.
generate = lambda do |source, owners, extra_env: {}|
  Dir.mktmpdir('dd_gen', ROOT) do |dir|
    path = File.join(dir, 'dd.rb')
    File.write(path, source)
    env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => 'dd', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(NATIVE_SRCS), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => owners.join(','), 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
            'BC2CPP_BUILD_GEMS' => Shellwords.join(BUILD_GEMS.map { |n, d| "#{n}=#{d}" }),
            NomethodReviewed::ALLOW_ENV => 'allow' }
    out, err, status = Open3.capture3(env.merge(extra_env), RbConfig.ruby, File.join(TOOL_DIR, 'bc2cpp.rb'), path)
    abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?
    [out, err]
  end
end

if run_unit && have_mrbc
  puts 'unit: the registry after DoubleDefinitions.settle'
  settled = lambda do |source|
    Dir.mktmpdir('dd_unit', ROOT) do |dir|
      path = File.join(dir, 'unit.rb')
      File.write(path, source)
      ireps, root = compile_ireps([path], 'unit', dir)
      registry = build_registry(ireps, root)[0]
      before = registry.transform_values(&:dup)
      report = DoubleDefinitions.settle(registry)
      [registry, before, report, ireps]
    end
  end
  defs_of = ->(registry, owner, name) { registry.fetch(name, []).select { |d| d.owner == owner } }

  registry, before, report, = settled.call(<<~'RUBY')
    class Dd
      def a; 1; end
      def a; 2; end
      attr_reader :b
      def b; 1; end
      def c; 1; end
      attr_reader :c
      def d; 1; end
      alias d a
      def e; 1; end
      alias_method :e, :a
      def f; 1; end
      undef f
      def g; 1; end
      private :g
      def g; 2; end
      def h; 1; end
      def h; 2; end if $x
      def self.s; 1; end
      class << self
        def s; 2; end
      end
      def only; 1; end
    end
  RUBY
  check.call('a def twice keeps one definition', defs_of.call(registry, 'Dd', 'a').size == 1 && defs_of.call(before, 'Dd', 'a').size == 2)
  check.call('the kept def is the last one', defs_of.call(registry, 'Dd', 'a').first.irep == defs_of.call(before, 'Dd', 'a').last.irep)
  check.call('attr_reader then def keeps the def', defs_of.call(registry, 'Dd', 'b').map(&:kind) == [nil] && defs_of.call(registry, 'Dd', 'b').first.irep)
  check.call('def then attr_reader keeps the accessor', defs_of.call(registry, 'Dd', 'c').map(&:kind) == [:ivar_accessor])
  %w[d e f].each do |name|
    left = defs_of.call(registry, 'Dd', name)
    check.call("a later alias/alias_method/undef of #{name} leaves one body-less marker", left.size == 1 && left.first.irep.nil? && left.first.kind.nil?)
  end
  check.call('a def redefined after `private :g` is the public last one',
             defs_of.call(registry, 'Dd', 'g').map(&:visibility) == [:public] && defs_of.call(before, 'Dd', 'g').first.visibility == :private)
  check.call('a conditional last def withdraws the group to a marker',
             defs_of.call(registry, 'Dd', 'h').map(&:irep) == [nil] && report.withdrawn.include?('Dd#h'))
  check.call('def self.s then class << self def s keeps the last on the singleton owner',
             defs_of.call(registry, 'Dd.singleton', 's').size == 1 && defs_of.call(before, 'Dd.singleton', 's').size == 2)
  check.call('a name defined once is untouched', defs_of.call(registry, 'Dd', 'only') == defs_of.call(before, 'Dd', 'only'))
  check.call('no (owner, name) is left with two definitions',
             registry.each_value.none? { |defs| defs.group_by(&:owner).values.any? { |g| g.size > 1 } })

  registry, before, = settled.call(<<~'RUBY')
    module Mf
      def helper; 1; end
      module_function :helper
      def helper; 2; end
    end
    class Other
      def x; 1; end
    end
    class Other2 < Other
      def x; 2; end
    end
  RUBY
  copy = defs_of.call(registry, 'Mf.singleton', 'helper')
  check.call('a module_function copy of a replaced body becomes a marker', copy.size == 1 && copy.first.kind.nil? && copy.first.copy_irep.nil?)
  check.call('definitions on different owners are left alone', registry['x'].map(&:owner) == %w[Other Other2])

  puts 'unit: C++ spellings'
  suffixes = DoubleDefinitions.symbol_suffixes(
    [MethodDef.new(name: 'singleton_make', owner: 'W', irep: 'i1'), MethodDef.new(name: 'make', owner: 'W.singleton', irep: 'i2'),
     MethodDef.new(name: 'bar_baz', owner: 'Foo', irep: 'i3'), MethodDef.new(name: 'baz', owner: 'Foo_bar', irep: 'i4'),
     MethodDef.new(name: 'plain', owner: 'W', irep: 'i5')],
    ->(owner, name) { owner.gsub(/[:.]/, '_') + "_#{name}" }
  )
  check.call('the second of two clashing pairs is suffixed, the rest are not',
             suffixes == { ['W.singleton', 'make'] => '$2', ['Foo_bar', 'baz'] => '$2' })
end

# -- 2. generated code ---------------------------------------------------------------------------

impls = ->(code) { code.scan(/^mrb_value (\S+)_impl\(mrb_state\* M/).flatten }
registrations = lambda do |code|
  code.scan(/^  mrb_define_(?:class_|private_)?method\(M, (\w+), "((?:\\x[0-9a-f]{2})+)", (\S+),/).map do |owner, hex, entry|
    [owner, [hex.scan(/\\x(\h\h)/).flatten.join].pack('H*'), entry]
  end
end
body_of = ->(code, owner_name) { code[/^\/\/ #{Regexp.escape(owner_name)} \(compiled from irep.*?(?=^\/\/ |\z)/m].to_s }

if run_generated && have_mrbc
  puts 'generated code: each form compiled alone'
  codes = {}
  FORMS.each do |form|
    code, log = generate.call(DD.program([form]), form.owners)
    codes[form.name] = [code, log]
    names = impls.call(code)
    check.call("#{form.name}: every _impl is defined once", names.size == names.uniq.size)
    regs = registrations.call(code).map { |owner, name, _entry| [owner, name] }
    check.call("#{form.name}: no (owner, name) is registered twice", regs.size == regs.uniq.size)
  end

  get = ->(name) { codes.fetch(name) }
  one_body = lambda do |name, owner, method|
    code, = get.call(name)
    code.scan(/^\/\/ #{Regexp.escape(owner)}##{Regexp.escape(method)} \(compiled from irep/).size
  end
  has = ->(name, text) { get.call(name).first.include?(text) }
  log_has = ->(name, text) { get.call(name).last.include?(text) }

  if FORMS.any? { |f| f.name == 'attr_then_def' }
    check.call('attr_then_def: the def is compiled and called directly, never the attr_reader',
               one_body.call('attr_then_def', 'Game::Screen', 'v_attr_then_def') == 1 &&
               !has.call('attr_then_def', 'LEXICAL_SELF_IVAR_ACCESSOR :v_attr_then_def') &&
               get.call('attr_then_def').first.match?(/(?:LEXICAL|CLOSED_WORLD)_SELF :v_attr_then_def -> Game::Screen#v_attr_then_def/))
    check.call('attr_then_def: the log names the kept definition', log_has.call('attr_then_def', 'LAST Game::Screen#v_attr_then_def (1 earlier)'))
  end
  if FORMS.any? { |f| f.name == 'def_then_attr' }
    check.call('def_then_attr: the dead def is not emitted', one_body.call('def_then_attr', 'Game::ChipSet', 'v_def_then_attr') == 0)
  end
  if FORMS.any? { |f| f.name == 'attr_then_define_method' }
    check.call('attr_then_define_method: the define_method body is the one compiled, not an accessor',
               one_body.call('attr_then_define_method', 'Game::Map', 'v_attr_then_define_method') == 1 &&
               !has.call('attr_then_define_method', 'IVAR_ACCESSOR :v_attr_then_define_method'))
  end
  if FORMS.any? { |f| f.name == 'def_then_define_method' }
    check.call('def_then_define_method: one body',
               one_body.call('def_then_define_method', 'Game::Timer', 'v_def_then_define_method') == 1)
  end
  if FORMS.any? { |f| f.name == 'define_method_then_def' }
    check.call('define_method_then_def: one body', one_body.call('define_method_then_def', 'Game::Shop', 'v_define_method_then_def') == 1)
  end
  if FORMS.any? { |f| f.name == 'def_then_def' }
    check.call('def_then_def: one body, the last (returns 2)',
               one_body.call('def_then_def', 'Game::Troop', 'v_def_then_def') == 1 &&
               body_of.call(get.call('def_then_def').first, 'Game::Troop#v_def_then_def').include?('mrb_fixnum_value(2)') &&
               !body_of.call(get.call('def_then_def').first, 'Game::Troop#v_def_then_def').include?('mrb_fixnum_value(1)'))
  end
  if FORMS.any? { |f| f.name == 'triple_def_raises' }
    check.call('triple_def_raises: one body, the third (raises)',
               one_body.call('triple_def_raises', 'Game::EnemyAi', 'v_triple_def_raises') == 1 &&
               body_of.call(get.call('triple_def_raises').first, 'Game::EnemyAi#v_triple_def_raises').include?('"\x74\x68\x69\x72\x64"'))
  end
  if FORMS.any? { |f| f.name == 'reopened_class' }
    check.call('reopened_class: one body, the reopened one (returns 2)',
               one_body.call('reopened_class', 'Game::Enemy', 'v_reopened_class') == 1 &&
               body_of.call(get.call('reopened_class').first, 'Game::Enemy#v_reopened_class').include?('mrb_fixnum_value(2)'))
  end
  if FORMS.any? { |f| f.name == 'alias_over_def' }
    check.call('alias_over_def: the aliased names are neither compiled, registered nor called directly',
               %w[b c].all? do |n|
                 one_body.call('alias_over_def', 'Game::Party', "#{n}_alias_over_def").zero? &&
                   registrations.call(get.call('alias_over_def').first).none? { |_o, name, _e| name == "#{n}_alias_over_def" } &&
                   !has.call('alias_over_def', "LEXICAL_SELF :#{n}_alias_over_def")
               end)
  end
  if FORMS.any? { |f| f.name == 'alias_then_redefine' }
    check.call('alias_then_redefine: the redefined original is the one compiled',
               one_body.call('alias_then_redefine', 'Game::Actors', 'a_alias_then_redefine') == 1 &&
               body_of.call(get.call('alias_then_redefine').first, 'Game::Actors#a_alias_then_redefine').include?('mrb_fixnum_value(2)'))
  end
  if FORMS.any? { |f| f.name == 'conditional_def' }
    check.call('conditional_def: a conditional last def withdraws the name (no body, no registration, no direct call)',
               %w[v w].all? do |n|
                 name = "#{n}_conditional_def"
                 one_body.call('conditional_def', 'Game::Actor', name).zero? &&
                   registrations.call(get.call('conditional_def').first).none? { |_o, rn, _e| rn == name } &&
                   !has.call('conditional_def', "LEXICAL_SELF :#{name}")
               end && log_has.call('conditional_def', 'WITHDRAWN Game::Actor#v_conditional_def'))
  end
  if FORMS.any? { |f| f.name == 'private_visibility' }
    regs = registrations.call(get.call('private_visibility').first)
    check.call('private_visibility: v is registered once, private; w once, public',
               get.call('private_visibility').first.scan(/mrb_define_private_method\(M, \w+, "\\x76\\x5f/).size == 1 &&
               regs.count { |_o, name, _e| name == 'v_private_visibility' } == 1 &&
               regs.count { |_o, name, _e| name == 'w_private_visibility' } == 1)
  end
  if FORMS.any? { |f| f.name == 'super_into_double' }
    check.call('super_into_double: the parent has one body', one_body.call('super_into_double', 'Game::NumberInput', 'v_super_into_double') == 1)
  end
  if FORMS.any? { |f| f.name == 'singleton_vs_instance_symbol' }
    code, = get.call('singleton_vs_instance_symbol')
    check.call('singleton_vs_instance_symbol: the two bodies have distinct symbols',
               impls.call(code).grep(/\AGame__Battle_singleton_make/).sort == %w[Game__Battle_singleton_make Game__Battle_singleton_make$2])
    check.call('singleton_vs_instance_symbol: each registration names its own entry',
               registrations.call(code).select { |_o, n, _e| %w[make singleton_make].include?(n) }.map { |o, n, e| [o, n, e] }.sort ==
               [['bc2cpp_owner_reg_Game__Battle', 'singleton_make', 'Game__Battle_singleton_make'],
                ['bc2cpp_owner_reg_Game__Battle_singleton', 'make', 'Game__Battle_singleton_make$2']])
  end
  if FORMS.any? { |f| f.name == 'sdef_then_sdef' }
    check.call('sdef_then_sdef: one body', one_body.call('sdef_then_sdef', 'Game::Party.singleton', 'm_sdef_then_sdef') == 1)
  end
  if FORMS.any? { |f| f.name == 'sdef_then_sclass_def' }
    check.call('sdef_then_sclass_def: one body', one_body.call('sdef_then_sclass_def', 'Game::States.singleton', 'm_sdef_then_sclass_def') == 1)
  end
  if FORMS.any? { |f| f.name == 'module_function_double' }
    code, = get.call('module_function_double')
    names = registrations.call(code).map { |_o, name, _e| name }
    check.call('module_function_double: the copy of a replaced body is neither compiled nor registered',
               one_body.call('module_function_double', 'RGSS', 'helper_module_function_double').zero? &&
               !names.include?('helper_module_function_double'))
    check.call('module_function_double: a copy over `def self.f` is the one body, registered once',
               one_body.call('module_function_double', 'RGSS', 'f_module_function_double') == 1 &&
               names.count('f_module_function_double') == 1)
  end

  puts 'generated code: the programs around the fixture'
  # A clash that is not a double definition: two different pairs with one spelling, no wired owner involved.
  code, = generate.call("class DdFoo\n  def bar_baz; 1; end\nend\nclass DdFoo_bar\n  def baz; 2; end\nend\n", %w[DdFoo DdFoo_bar])
  check.call('two owners whose names join to one spelling get distinct symbols',
             impls.call(code).grep(/DdFoo.*bar_baz|DdFoo_bar_baz/).sort == %w[DdFoo_bar_baz DdFoo_bar_baz$2])
  # No double definition anywhere: no suffix, no report, the output of a program that never had the problem.
  plain = "class DdOne\n  def a; 1; end\n  attr_reader :b\n  def c; a; end\nend\nclass DdTwo\n  def a; 2; end\nend\n"
  code, log = generate.call(plain, %w[DdOne DdTwo])
  check.call('a program without a double definition has no report and no suffixed symbol',
             !log.include?('== double definitions') && !code.include?('$2'))
  # The same program with the pass left out must give the same text (the kill switch is not offered; the
  # mutation check covers a pass that changes it).
  code2, = generate.call(plain, %w[DdOne DdTwo])
  check.call('generation is deterministic', code == code2)
  all_code, all_log = generate.call(DD.program, DD::OWNERS)
  check.call('all forms together: every _impl is defined once', impls.call(all_code).size == impls.call(all_code).uniq.size)
  regs = registrations.call(all_code).map { |o, n, _e| [o, n] }
  check.call('all forms together: no (owner, name) is registered twice', regs.size == regs.uniq.size)
  check.call('all forms together: the report counts every kept and withdrawn name',
             all_log.include?('== double definitions (') && all_log.scan(/^  WITHDRAWN /).size == 2)
end

# -- 3. behaviour --------------------------------------------------------------------------------

ran_behaviour = false
if run_behaviour
  unless have_mrbc && tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
    puts '-- SKIP behavioural comparison: needs a host mrbc, 3rd/mruby, rake and g++'
  else
    ran_behaviour = true
    GEM_RAKE = <<~'RAKE'
      require 'shellwords'
      ROOT = ENV.fetch('BC2CPP_ROOT')
      require "#{ROOT}/tools/bc2cpp/compiled_gems"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

      MRuby::Gem::Specification.new('bc2cpp-dd-test') do |spec|
        spec.license = 'MIT'
        spec.author = 'rpg-maker-clone'
        spec.summary = 'harness: a double-definition fixture compiled, registered unless DD_INTERPRETED is set'

        generated = "#{build_dir}/dd_gen.cpp"
        prerequisites = [ENV.fetch('BC2CPP_DD_FIXTURE'), *Dir["#{ENV.fetch('BC2CPP_TOOL_DIR')}/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
        file generated => prerequisites do
          FileUtils.mkdir_p build_dir
          gems = NomethodReviewedProbe.wio_gems(ROOT)
          native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
          env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'dd', 'OUT_DIR' => build_dir,
                  'ONLY_OWNERS' => ENV.fetch('BC2CPP_DD_OWNERS'),
                  'NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
                  'SKIP_UNSUPPORTED' => '1', 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                  'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                  NomethodReviewed::ALLOW_ENV => 'allow' }
          cmd = "#{RbConfig.ruby.shellescape} #{ENV.fetch('BC2CPP_TOOL_DIR')}/bc2cpp.rb #{ENV.fetch('BC2CPP_DD_FIXTURE').shellescape} " \
                "> #{generated.shellescape} 2> #{build_dir}/dd.diag"
          sh env, cmd
        end
        file "#{dir}/src/register.cxx" => generated
        cxx.include_paths << build_dir
        cxx.include_paths << "#{ROOT}/include"
      end
    RAKE

    # DD_INTERPRETED leaves both the instance type setup and the registration out: the same binary then
    # runs nothing the generator produced.
    REGISTER_CXX = <<~'CPP'
      #include <stdlib.h>
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/compile.h>
      #include "dd_gen.cpp"

      // Is the method a class finds for a name a C function (a compiled entry) rather than bytecode?
      static mrb_value dd_compiled_p(mrb_state* M, mrb_value) {
        mrb_value klass;
        mrb_sym name;
        mrb_get_args(M, "Cn", &klass, &name);
        struct RClass* c = mrb_class_ptr(klass);
        mrb_method_t m = mrb_method_search_vm(M, &c, name);
        return mrb_bool_value(!MRB_METHOD_UNDEF_P(m) && MRB_METHOD_CFUNC_P(m));
      }

      static const char* const kFixture = R"DDFX(@@FIXTURE@@)DDFX";

      extern "C" void mrb_bc2cpp_dd_test_gem_init(mrb_state* M) {
        mrb_define_method(M, M->kernel_module, "dd_compiled?", dd_compiled_p, MRB_ARGS_REQ(2));
        mrb_load_string(M, kFixture);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
        if (getenv("DD_INTERPRETED")) return;
        bc2cpp_set_instance_tts(M);
        bc2cpp_register_owner_methods(M);
      }

      extern "C" void mrb_bc2cpp_dd_test_gem_final(mrb_state*) {}
    CPP

    # The core-only build is mruby's own mrblib with only mruby-io (for puts) on top: the *-ext methods are
    # absent, so the driver tolerates what it lacks in both runs.
    VARIANTS = {
      'full-core' => ["conf.gembox 'full-core'", ''],
      'core-only' => ["conf.gem core: 'mruby-bin-mruby'\n  conf.gem core: 'mruby-bin-mrbc'\n  conf.gem core: 'mruby-io'", ''],
      'int32' => ["conf.gembox 'full-core'", "[conf.cc, conf.cxx].each { |t| t.defines << 'MRB_32BIT' << 'MRB_INT32' }"]
    }.freeze

    config_for = lambda do |variant|
      variant_gems, defines = VARIANTS.fetch(variant)
      <<~RUBY
        MRuby::Build.new('host') do |conf|
          toolchain :gcc
          #{variant_gems}
          conf.gem ENV['BC2CPP_HARNESS_GEM']
          #{defines}
          conf.cxx.flags << '-std=gnu++17'
          enable_cxx_exception
          enable_debug
          [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
        end
      RUBY
    end

    work = ENV['DD_DIR'] || Dir.mktmpdir('bc2cpp_dd', ROOT)
    FileUtils.mkdir_p(work)
    fixture = DD.program(FORMS)
    driver = DD.driver(FORMS)
    owners = FORMS.flat_map(&:owners).uniq
    File.write(File.join(work, 'fixture.rb'), fixture)
    File.write(File.join(work, 'driver.rb'), driver)
    File.write(File.join(work, 'probe.rb'), DD.probe(FORMS))

    build = lambda do |variant|
      File.write(File.join(work, "config_#{variant}.rb"), config_for.call(variant))
      gem_dir = File.join(work, "gem_#{variant}")
      FileUtils.mkdir_p(File.join(gem_dir, 'src'))
      File.write(File.join(gem_dir, 'mrbgem.rake'), GEM_RAKE)
      File.write(File.join(gem_dir, 'src/register.cxx'), REGISTER_CXX.sub('@@FIXTURE@@') { fixture })
      dir = File.join(work, variant)
      FileUtils.mkdir_p(File.join(dir, 'repos/host'))
      FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(dir, 'repos/host/mgem-list'))
      env = { 'BC2CPP_ROOT' => ROOT, 'BC2CPP_TOOL_DIR' => TOOL_DIR, 'MRUBY_CONFIG' => File.join(work, "config_#{variant}.rb"),
              'MRUBY_BUILD_DIR' => dir, 'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_DD_OWNERS' => owners.join(','),
              'BC2CPP_DD_FIXTURE' => File.join(work, 'fixture.rb') }
      env['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if variant == 'int32'
      env.merge!(Bc2cppCxx.rake_env)
      out, status = Open3.capture2e(env, 'rake', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
      File.write(File.join(work, "#{variant}.log"), out)
      bin = File.join(dir, 'host/bin/mruby')
      [status.success? && File.exist?(bin) ? bin : nil, out, dir]
    end

    run_driver = lambda do |bin, interpreted|
      env = interpreted ? { 'DD_INTERPRETED' => '1' } : {}
      Open3.capture2e(env, bin, File.join(work, 'driver.rb')).first
    end
    run_probe = lambda do |bin, interpreted|
      env = interpreted ? { 'DD_INTERPRETED' => '1' } : {}
      Open3.capture2e(env, bin, File.join(work, 'probe.rb')).first
    end

    (ENV['DD_VARIANTS'] || VARIANTS.keys.join(',')).split(',').each do |variant|
      puts "double definitions (#{variant}): build"
      bin, log, dir = build.call(variant)
      check.call("#{variant}: the harness builds", !bin.nil?)
      puts log.lines.last(30).join unless bin
      next unless bin

      base_out = run_driver.call(bin, true)
      comp_out = run_driver.call(bin, false)
      check.call("#{variant}: the interpreter runs the driver", base_out.lines.last == "end\n")
      check.call("#{variant}: the compiled run finishes the driver", comp_out.lines.last == "end\n")
      expected = FORMS.sum { |f| f.driver.scan('dd_show(').size }
      check.call("#{variant}: every form printed a line (#{expected})", base_out.lines.size == expected + 1)
      check.call("#{variant}: driver output, #{base_out.lines.size} lines, interpreted and compiled identical", base_out == comp_out)
      unless base_out == comp_out
        base_out.lines.zip(comp_out.lines).reject { |a, b| a == b }.first(20).each do |a, b|
          puts "    interpreted: #{a}    compiled:    #{b}"
        end
      end
      puts base_out if ENV['DD_SHOW']
      probe_compiled = run_probe.call(bin, false)
      probe_interpreted = run_probe.call(bin, true)
      puts probe_compiled if ENV['DD_SHOW']
      check.call("#{variant}: the interpreted run has no compiled entry", !probe_interpreted.include?(': true'))
      DD.probes(FORMS).each do |form, klass, name, want|
        got = probe_compiled[/^#{Regexp.escape("#{klass} #{name}")}: (\w+)$/, 1]
        check.call("#{variant}: #{form}: #{klass}##{name} #{want ? 'is' : 'is not'} a compiled entry (non-vacuity)", got == want.to_s)
      end
      by_line = ->(out, label) { out.lines.find { |l| l.start_with?("#{label}: ") } }
      check.call("#{variant}: the last definition's exception is raised",
                 by_line.call(comp_out, 'triple_def_raises self') == "triple_def_raises self: raised ArgumentError\n") if FORMS.any? { |f| f.name == 'triple_def_raises' }
      if FORMS.any? { |f| f.name == 'live_def_raises' }
        interpreted_line = by_line.call(base_out, 'live_def_raises self')
        check.call("#{variant}: live_def_raises: compiled prints the interpreter's line (#{interpreted_line.to_s.strip})",
                   by_line.call(comp_out, 'live_def_raises self') == interpreted_line)
        check.call("#{variant}: live_def_raises: a core-only build raises (String#succ is absent), full-core does not",
                   variant == 'core-only' ? interpreted_line.include?('raised') : interpreted_line.include?('ac'))
      end
      gen = File.join(dir, 'host/mrbgems/bc2cpp-dd-test/dd_gen.cpp')
      File.write(File.join(work, "#{variant}_gen.cpp"), File.read(gen)) if File.exist?(gen)
    end
    FileUtils.rm_rf(work) unless ENV['DD_DIR']
  end
end

if failures.empty?
  puts "bc2cpp double definition check: PASS#{ran_behaviour ? '' : ' (no behavioural run)'}"
else
  warn "bc2cpp double definition check: #{failures.size} failure(s)"
  exit 1
end
