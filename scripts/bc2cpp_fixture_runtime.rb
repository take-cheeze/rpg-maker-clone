# frozen_string_literal: true

# Shared by the bc2cpp checks that compile a fixture with bc2cpp.rb and run it
# against a real mruby: generation (open or closed world), the C++ driver that
# registers the compiled methods over the interpreted ones, and the run.
#
# Two mruby builds are used, both optional (a check prints SKIP without them):
#   BC2CPP_MRUBY_CORE  a dir with lib/libmruby_core.a and include/ (no gems);
#   BC2CPP_MRUBY_FULL  the same with lib/libmruby.a and the full-core gems, for
#                      fixtures that need Enumerable, Integer#positive?, ...
# Both must be built from the patched 3rd/mruby the tree carries.
# BC2CPP_CXXFLAGS adds compiler flags, e.g. -DMRB_INT32 for a build whose mrb_int is 32 bits
# wide (the Emscripten/Wio/PSP width); run with that build's own MRBC.
# BC2CPP_KEEP_DIR=path keeps the last fixture directory (generated code, binary).
# BC2CPP_PROBE_LOG=file appends one evidence line per generation and run (what the fixture declares but
# does not compile, how often a compiled entry ran, a failed build or binary): the channel the mutation
# harnesses read to tell a kill by the intended assertion from a kill by a crash
# (scripts/bc2cpp_mutation_support.rb).
require 'etc'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/compiled_gems'
require_relative '../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'bc2cpp_cxx'

module Bc2cppFixtureRuntime
  ROOT = File.expand_path('..', __dir__)
  # BC2CPP_TOOL names another bc2cpp.rb (a mutant copy, scripts/bc2cpp_class_pools_mutation_check.rb).
  BC2CPP = ENV.fetch('BC2CPP_TOOL') { File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb') }

  # The compiled leg ran no registered entry (nothing was registered, or the scenario never reached
  # one): the interpreted and compiled sections would be the same bytecode run twice.
  class VacuousCompiledLeg < StandardError; end

  module_function

  def probe(line)
    log = ENV.fetch('BC2CPP_PROBE_LOG', nil)
    File.open(log, 'a') { |file| file.puts(line) } if log && !log.empty?
  end

  def mrbc
    ENV['MRBC'] || 'mrbc'
  end

  # A build dir holding `library` and include/, from `env` or nil.
  def build_dir(env, library)
    dir = ENV[env]
    dir if dir && File.exist?(File.join(dir, 'lib', library)) && File.directory?(File.join(dir, 'include'))
  end

  def core
    build_dir('BC2CPP_MRUBY_CORE', 'libmruby_core.a') ||
      Dir[File.join(ROOT, 'build*/mruby/host/mrbc')].find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) }
  end

  def full
    build_dir('BC2CPP_MRUBY_FULL', 'libmruby.a')
  end

  def compiler?
    system('g++', '--version', out: File::NULL, err: File::NULL)
  end

  FULL_CORE_CONFIG = <<~RUBY
    MRuby::Build.new('host') do |conf|
      toolchain :gcc
      conf.gembox 'full-core'
      conf.gem '#{ROOT}/3rd/mruby-stringio'
      conf.cxx.flags << '-std=gnu++17'
      enable_cxx_exception
      enable_debug
      [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
    end
  RUBY

  # A full-core libmruby build dir (lib/libmruby.a and include/), for fixtures that need Fiber,
  # Integer#step and the rest of mrblib: BC2CPP_MRUBY_FULL, else one built here with rake
  # (minutes; BC2CPP_FULL_BUILD_DIR keeps it for the next check). nil without rake, g++ or
  # 3rd/mruby, so the caller can skip the behavioural half.
  def full_or_build
    return full if full
    return nil unless system('rake', '--version', out: File::NULL, err: File::NULL) && compiler? &&
                      File.exist?(File.join(ROOT, '3rd/mruby/Rakefile'))

    work = ENV['BC2CPP_FULL_BUILD_DIR'] || (@full_build_dir ||= Dir.mktmpdir('bc2cpp_full'))
    host = File.join(work, 'host')
    return host if File.exist?(File.join(host, 'lib/libmruby.a'))

    FileUtils.mkdir_p(File.join(work, 'repos/host'))
    FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(work, 'repos/host/mgem-list'))
    File.write(File.join(work, 'config.rb'), FULL_CORE_CONFIG)
    env = { 'MRUBY_CONFIG' => File.join(work, 'config.rb'), 'MRUBY_BUILD_DIR' => work }.merge(Bc2cppCxx.rake_env)
    out, status = Open3.capture2e(env, 'rake', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: File.join(ROOT, '3rd/mruby'))
    File.write(File.join(work, 'build.log'), out)
    raise "full-core mruby build failed:\n#{out.lines.last(30).join}" unless status.success?

    host
  end

  # Runs bc2cpp.rb over `source`. `closed` is the wio closed world with the
  # real core sources (what the model checks need); `only_owners` limits what
  # is compiled. Returns [code, stderr, dir-relative bytecode path].
  # `path` places the fixture below `dir`: a path under 3rd/mruby/mrblib/ makes bc2cpp treat
  # it as mruby's own Ruby (CoreDefs.core_source?), so a check can exercise the core-only proofs.
  # `extra` is more sources ([path, text] pairs) compiled after the fixture, e.g. engine Ruby
  # next to a core fixture. `build_gems` ([name, dir] pairs) adds gems to the closed-world build, whose
  # src/ and mrblib/ then count as outside native and Ruby sources.
  def generate(source, dir, closed: true, only_owners: nil, hot_methods: nil, path: 'fixture.rb', extra: [],
               native: [], foreign: [], build_gems: [])
    src = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(src))
    File.write(src, source)
    note_unlisted_classes(source, only_owners)
    extra_srcs = extra.map do |extra_path, text|
      File.join(dir, extra_path).tap { |file| FileUtils.mkdir_p(File.dirname(file)) && File.write(file, text) }
    end
    env = { 'MRBC' => mrbc, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir,
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_HOT_METHODS' => hot_methods }
    env['ONLY_OWNERS'] = only_owners.join(',') if only_owners
    if closed
      # `native`/`foreign` are [name, text] pairs of outside sources the closed world must scan.
      write_outside = lambda do |pairs|
        pairs.map { |name, text| File.join(dir, name).tap { |file| File.write(file, text) } }
      end
      natives = core_native_srcs("#{ROOT}/3rd/mruby") + Dir["#{ROOT}/mruby-rgss/src/*.cxx"] +
                external_gem_native_srcs(ROOT) + write_outside.call(native)
      env.merge!('NATIVE_SRCS' => Shellwords.join(natives),
                 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT) + write_outside.call(foreign)),
                 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).merge(build_gems.to_h).map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    code, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, src, *extra_srcs)
    raise "bc2cpp.rb failed:\n#{(err[-3000..] || err)}" unless status.success?

    File.write(File.join(dir, 'fixture_gen.cpp'), code)
    [code, err]
  end

  # A class the fixture declares that `only_owners` leaves out stays bytecode in both legs.
  def note_unlisted_classes(source, only_owners)
    return unless only_owners

    declared = source.scan(/^\s*(?:class|module)\s+([A-Z]\w*(?:::\w+)*)/).flatten.uniq
    unlisted = declared.reject { |name| only_owners.any? { |owner| owner.delete_suffix('.singleton') == name } }
    probe("unlisted-classes #{unlisted.join(' ')}") unless unlisted.empty?
  end

  ENTRY_LINE = %r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity (\d+)\)(.*)$}

  # [entry, owner, name, arity, extra] of every compiled entry point of `owners`.
  def compiled_entries(err, owners)
    err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
       .scan(ENTRY_LINE).select { |_entry, owner, *| owners.include?(owner) }
  end

  # `mrb_define_method` lines registering every compiled entry point of `owners`. With
  # `exact_arity` an entry registers MRB_ARGS_REQ(arity) as the build's own registration does for
  # a method with required parameters only, so the VM's argument-count check runs; otherwise
  # MRB_ARGS_ANY() (the entry's own mrb_get_args is then the only check). With `probe` each entry
  # goes through its counting trampoline (see `run`).
  def registrations(err, owners, exact_arity: false, probe: false)
    compiled_entries(err, owners).each_with_index.map do |(entry, owner, name, arity, extra), index|
      entry = "bc2cpp_probe_#{index}" if probe
      holder = owner.delete_suffix('.singleton')
      scope = holder.split('::').inject('mrb_obj_value(M->object_class)') do |outer, part|
        "mrb_const_get(M, #{outer}, mrb_intern_cstr(M, #{part.dump}))"
      end
      klass = "mrb_class_ptr(#{scope})"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, #{exact_arity ? "MRB_ARGS_REQ(#{arity})" : 'MRB_ARGS_ANY()'});"
    end
  end

  # Builds and runs a program: `body` is C++ run once per VM (it sees `M`, and
  # `compiled` says whether the compiled methods are registered). The fixture's
  # bytecode is loaded first. Returns [built, output]. With `envs` (an Array of
  # environment Hashes) the binary runs once per entry, each in its own process
  # so one crashing scenario cannot hide the others, and `output` is the Array
  # of their outputs paired with the exit status: [[output, success], ...].
  def run(dir, err, owners, body, build:, full: false, vms: [false, true], envs: nil, exact_arity: false)
    entries = compiled_entries(err, owners)
    # An interpreted-only run registers nothing; a compiled one with nothing to register is two interpreted runs.
    if vms.include?(true) && entries.empty?
      raise VacuousCompiledLeg, "no compiled entry point of #{owners.join(', ')} to register (the fixture's own classes " \
                                'must be in the owner list and compiled)'
    end

    regs = registrations(err, owners, exact_arity: exact_arity, probe: true).join("\n")
    probe_defs = entries.each_index.map do |i|
      "static mrb_value bc2cpp_probe_#{i}(mrb_state* M, mrb_value self) { ++bc2cpp_probe_hits[#{i}]; " \
        "return #{entries[i].first}(M, self); }"
    end.join("\n")
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      static int dispatches = 0;
      // Every dynamic dispatch the compiled bodies make.
      #define mrb_funcall_argv(M, ...) (++dispatches, (mrb_funcall_argv)(M, __VA_ARGS__))
      #define mrb_funcall_id(M, ...) (++dispatches, (mrb_funcall_id)(M, __VA_ARGS__))
      #define mrb_funcall(M, ...) (++dispatches, (mrb_funcall)(M, __VA_ARGS__))
      #include "fixture_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/array.h>
      #include <mruby/class.h>
      #include <mruby/data.h>
      #include <mruby/hash.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      #{full ? '' : 'extern "C" void mrb_init_mrblib(mrb_state*) {}'}
      #include <cstdlib>
      // Runtime probe: counts the VM dispatches that reach a registered compiled entry, so a compiled leg
      // that only ever ran bytecode is detected (BC2CPP_PROBE_FILE, read by Bc2cppFixtureRuntime.run).
      static unsigned long bc2cpp_probe_hits[#{entries.size + 1}];
      #{probe_defs}
      static void bc2cpp_probe_report() {
        const char* path = std::getenv("BC2CPP_PROBE_FILE");
        if (!path) return;
        unsigned long total = 0;
        for (unsigned long h : bc2cpp_probe_hits) total += h;
        if (std::FILE* f = std::fopen(path, "a")) { std::fprintf(f, "hits %lu\\n", total); std::fclose(f); }
      }
      static void show(mrb_state* M, const char* label, mrb_value v) {
        mrb_value s = mrb_inspect(M, v);
        std::printf("%s => %.*s\\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
      static void show_exc(mrb_state* M, const char* label) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value cls = mrb_str_new_cstr(M, mrb_obj_classname(M, e));
        std::printf("%s => raised %.*s\\n", label, (int)RSTRING_LEN(cls), RSTRING_PTR(cls));
      }
      // Calls obj.meth(*args) and shows its value or the exception class.
      // A compiled run also prints, indented, how many dynamic dispatches the call made.
      static bool compiled = false;
      static mrb_value call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                            const mrb_value* argv = nullptr) {
        dispatches = 0;
        mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
        int made = dispatches;
        if (M->exc) show_exc(M, label); else show(M, label, r);
        if (compiled) std::printf("  dispatches=%d\\n", made);
        return M->exc ? mrb_nil_value() : r;
      }
      #{body}
      static int run_vm(const std::vector<uint8_t>& bin, bool with_compiled) {
        mrb_state* M = #{full ? 'mrb_open()' : 'mrb_open_core()'};
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        compiled = with_compiled;
        if (with_compiled) {
          bc2cpp_set_instance_tts(M);
      #{regs}
        }
        int rc = scenario(M);
        if (with_compiled) bc2cpp_probe_report();
        mrb_close(M);
        if (with_compiled) bc2cpp_reset_owner_classes();
        return rc;
      }
      int main(int, char** argv) {
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        for (int vm = 0; vm < #{vms.size}; ++vm) {
          static const bool modes[] = { #{vms.map { |v| v ? 'true' : 'false' }.join(', ')} };
          std::printf("== %s\\n", modes[vm] ? "compiled" : "interpreted");
          if (int rc = run_vm(bin, modes[vm])) return rc;
        }
        return 0;
      }
    CPP
    lib = full ? "#{build}/lib/libmruby.a" : "#{build}/lib/libmruby_core.a"
    binary = File.join(dir, 'fixture')
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w]
    flags << '-DMRB_NO_GEMS' unless full
    flags.concat(Shellwords.split(ENV.fetch('BC2CPP_CXXFLAGS', '')))
    built = Bc2cppCxx.system(*flags, "-I#{dir}", "-I#{build}/include", "-I#{ROOT}/3rd/mruby/include",
                   "-I#{ROOT}/mruby-rgss/src", "-I#{ROOT}/include", File.join(dir, 'main.cpp'), lib, '-lm', '-o', binary)
    unless built
      probe('build-failed')
      return [false, '']
    end

    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
    mrb = File.join(dir, 'fixture.mrb')
    launch = lambda do |env, index|
      hits = File.join(dir, "probe_hits.#{index}")
      out = IO.popen(env.to_h.merge('BC2CPP_PROBE_FILE' => hits), [binary, mrb], err: %i[child out], &:read)
      ok = $?.success?
      check_probe(hits, vms, ok, env)
      [out, ok]
    end
    return [true, envs.each_with_index.map { |env, index| launch.call(env, index) }] if envs

    out, ok = launch.call({}, 0)
    [ok, out]
  end

  # The probe file holds one "hits N" line per compiled VM that finished its scenario.
  def check_probe(file, vms, ok, env)
    probe("binary-failed #{env.to_a.sort.inspect}") unless ok
    return unless vms.include?(true)

    hits = File.exist?(file) ? File.read(file)[/^hits (\d+)/, 1].to_i : nil
    probe("compiled-hits #{hits.inspect} #{env.to_a.sort.inspect}")
    return unless ok && hits.to_i.zero?

    raise VacuousCompiledLeg, 'the compiled VM finished its scenario without dispatching to any registered compiled entry'
  end

  # For a driver that registers compiled entries itself (a generated or hand-written register.cxx): put this before the
  # generated code and call bc2cpp_probe_report() once the scenario is over. Every mrb_define_*method of the generated
  # registration then goes through a counting thunk, as in `run`, so `probed_capture` can tell a compiled leg that ran
  # compiled code from one that only ran bytecode.
  PROBE_PROLOGUE = <<~'CPP'
    #include <mruby.h>
    #include <cstdio>
    #include <cstdlib>
    static unsigned long bc2cpp_probe_hits = 0;
    template <mrb_value (*F)(mrb_state*, mrb_value)>
    static mrb_value bc2cpp_probe_thunk(mrb_state* M, mrb_value self) { ++bc2cpp_probe_hits; return F(M, self); }
    #define mrb_define_method(M, c, n, f, a) (mrb_define_method)(M, c, n, bc2cpp_probe_thunk<f>, a)
    #define mrb_define_private_method(M, c, n, f, a) (mrb_define_private_method)(M, c, n, bc2cpp_probe_thunk<f>, a)
    #define mrb_define_class_method(M, c, n, f, a) (mrb_define_class_method)(M, c, n, bc2cpp_probe_thunk<f>, a)
    static void bc2cpp_probe_report() {
      const char* path = std::getenv("BC2CPP_PROBE_FILE");
      if (!path) return;
      if (std::FILE* f = std::fopen(path, "a")) { std::fprintf(f, "hits %lu\n", bc2cpp_probe_hits); std::fclose(f); }
    }
  CPP

  # Open3.capture2e for a driver built with PROBE_PROLOGUE: [output, status]. With `compiled` the run must have reported
  # at least one dispatch into a registered compiled entry (VacuousCompiledLeg otherwise).
  def probed_capture(*argv, compiled:, env: {})
    Dir.mktmpdir('probe') do |dir|
      file = File.join(dir, 'hits')
      out, status = Open3.capture2e(env.merge('BC2CPP_PROBE_FILE' => file), *argv)
      check_probe(file, [compiled], status.success?, env.merge('driver' => argv.last)) if compiled
      [out, status]
    end
  end

  # The lines of `output` between "== compiled"/"== interpreted" headers.
  def sections(output)
    output.split(/^== /).reject(&:empty?).to_h do |chunk|
      head, *rest = chunk.lines
      [head.strip, rest.map(&:chomp)]
    end
  end
end
