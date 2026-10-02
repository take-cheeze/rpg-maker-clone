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

      static const char* const kFixture = R"DDFX(@@FIXTURE@@)DDFX";

      extern "C" void mrb_bc2cpp_dd_test_gem_init(mrb_state* M) {
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
