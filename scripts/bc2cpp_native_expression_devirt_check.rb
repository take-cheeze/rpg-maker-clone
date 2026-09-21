#!/usr/bin/env ruby
# encoding: UTF-8

# Check conservative devirtualization expression generation from mruby C
# method registrations and implementations.
require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'
require_relative '../tools/bc2cpp/compiled_gems'

root = File.expand_path('..', __dir__)
core_sources = Dir[File.join(root, 'mruby-rgss/src/*.cxx')] +
               core_native_srcs(File.join(root, '3rd/mruby')) + external_gem_native_srcs(root)
generated = NativeExpressionDevirt.analyze(core_sources)
containers = NativeExpressionDevirt.analyze_containers(core_sources)
failures = []
check = lambda do |description, condition|
  puts "  #{condition ? 'ok' : 'FAIL'}  #{description}"
  failures << description unless condition
end

check.call('mruby BasicObject#! is generated from its registered C body',
           generated['!'] == 'mrb_bool_value(!mrb_test(recv))')
check.call('Array and Hash size bodies are generated; String size is declined',
           containers['size']&.map { |entry| entry[:owner][:class_name] } == %w[Array Hash] &&
             containers['size'].none? { |entry| entry[:expression].include?('RSTRING_CHAR_LEN') })
check.call('Array, Hash, and String empty? bodies are generated from their C implementations',
           containers['empty?']&.map { |entry| entry[:owner][:class_name] } == %w[Array Hash String])
check.call('Hash#to_hash is generated as an exact-class identity conversion',
           containers['to_hash']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Hash', 'recv']])
check.call('frame-reading C methods are not expression candidates',
           NativeExpressionDevirt.direct_return_expression(
             'mrb_get_args(mrb, "i", &n); return mrb_int_value(mrb, n);', 'mrb', 'self'
           ).nil?)

Dir.mktmpdir do |dir|
  source = File.join(dir, 'fixture.c')
  File.write(source, <<~'C')
    static mrb_value fixture_not(mrb_state *mrb, mrb_value self)
    {
      return mrb_bool_value(!mrb_test(self));
    }
    static const mrb_mt_entry fixture_methods[] = {
      MRB_MT_ENTRY(fixture_not, MRB_OPSYM(not), MRB_ARGS_NONE()),
      MRB_MT_ENTRY(fixture_not, MRB_OPSYM(not), MRB_ARGS_REQ(1)),
    };
  C
  check.call('a same-name registration with another arity disables generation',
             !NativeExpressionDevirt.analyze([source]).key?('!'))

  File.write(source, <<~'C')
    static mrb_value fixture_not(mrb_state *mrb, mrb_value self)
    {
      return mrb_bool_value(!mrb_test(self));
    }
    static mrb_value fixture_not_other(mrb_state *mrb, mrb_value self)
    {
      return mrb_false_value();
    }
    static const mrb_mt_entry fixture_methods[] = {
      MRB_MT_ENTRY(fixture_not, MRB_OPSYM(not), MRB_ARGS_NONE()),
      MRB_MT_ENTRY(fixture_not_other, MRB_OPSYM(not), MRB_ARGS_NONE()),
    };
  C
  check.call('different implementations registered under one name disable generation',
             !NativeExpressionDevirt.analyze([source]).key?('!'))
end

registry = { '!' => [MethodDef.new(name: '!', owner: '<native>', irep: nil, visibility: :public)] }
generator = CodeGen.new({}, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                        native_expression_devirt: generated,
                        native_container_devirt: containers)
code = generator.compile_native_primitive_send('!', 1, 'r2', [])
check.call('generated expression is emitted into bc2cpp output',
           code.include?("generated from mruby's registered C implementation") &&
             code.include?('mrb_bool_value(!mrb_test(r2))'))
container_code = generator.compile_native_primitive_send('size', 1, 'r3', [])
check.call('container output uses generated C expressions and falls back for other receiver classes',
           container_code.include?('M->array_class') && container_code.include?('M->hash_class') &&
             container_code.include?('mrb_funcall(M, r3, "size", 0)'))
hash_to_hash_code = generator.compile_native_primitive_send('to_hash', 1, 'r3', [])
check.call('generated Hash#to_hash is exact-class guarded and preserves dynamic fallback',
           hash_to_hash_code.include?('M->hash_class') &&
             hash_to_hash_code.include?('r1 = r3;') &&
             hash_to_hash_code.include?('mrb_funcall(M, r3, "to_hash", 0)'))
override_registry = {
  'size' => [
    MethodDef.new(name: 'size', owner: '<native>', irep: nil, visibility: :public),
    MethodDef.new(name: 'size', owner: 'Array', irep: 'Array#size', visibility: :public)
  ]
}
override_generator = CodeGen.new({}, override_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                 native_container_devirt: containers)
check.call('a Ruby override on a built-in container rejects generated native bodies',
           !override_generator.builtin_class_send_safe?('size', %w[Array Hash String]))

abort "#{failures.length} native expression devirtualization check(s) failed" unless failures.empty?
