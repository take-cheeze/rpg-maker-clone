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
# BC2CPP_KEEP_DIR=path keeps the last fixture directory (generated code, binary).
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/compiled_gems'
require_relative '../tools/bc2cpp/nomethod_reviewed_probe'

module Bc2cppFixtureRuntime
  ROOT = File.expand_path('..', __dir__)
  BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

  module_function

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

  # Runs bc2cpp.rb over `source`. `closed` is the wio closed world with the
  # real core sources (what the model checks need); `only_owners` limits what
  # is compiled. Returns [code, stderr, dir-relative bytecode path].
  def generate(source, dir, closed: true, only_owners: nil, hot_methods: nil)
    src = File.join(dir, 'fixture.rb')
    File.write(src, source)
    env = { 'MRBC' => mrbc, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir,
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_HOT_METHODS' => hot_methods }
    env['ONLY_OWNERS'] = only_owners.join(',') if only_owners
    if closed
      native = core_native_srcs("#{ROOT}/3rd/mruby") + Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(ROOT)
      env.merge!('NATIVE_SRCS' => Shellwords.join(native),
                 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
                 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    code, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, src)
    raise "bc2cpp.rb failed:\n#{(err[-3000..] || err)}" unless status.success?

    File.write(File.join(dir, 'fixture_gen.cpp'), code)
    [code, err]
  end

  # `mrb_define_method` lines registering every compiled entry point of `owners`.
  def registrations(err, owners)
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    entries.filter_map do |entry, owner, name, extra|
      next unless owners.include?(owner)

      holder = owner.delete_suffix('.singleton')
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{holder.dump})))"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
  end

  # Builds and runs a program: `body` is C++ run once per VM (it sees `M`, and
  # `compiled` says whether the compiled methods are registered). The fixture's
  # bytecode is loaded first. Returns [built, output].
  def run(dir, err, owners, body, build:, full: false, vms: [false, true])
    regs = registrations(err, owners).join("\n")
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
    built = system('g++', *flags, "-I#{dir}", "-I#{build}/include", "-I#{ROOT}/3rd/mruby/include",
                   "-I#{ROOT}/mruby-rgss/src", File.join(dir, 'main.cpp'), lib, '-lm', '-o', binary)
    return [false, ''] unless built

    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
    output = IO.popen([binary, File.join(dir, 'fixture.mrb')], err: %i[child out], &:read)
    [$?.success?, output]
  end

  # The lines of `output` between "== compiled"/"== interpreted" headers.
  def sections(output)
    output.split(/^== /).reject(&:empty?).to_h do |chunk|
      head, *rest = chunk.lines
      [head.strip, rest.map(&:chomp)]
    end
  end
end
