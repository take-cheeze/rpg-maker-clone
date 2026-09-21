#!/usr/bin/env ruby
# encoding: UTF-8

# Check conservative devirtualization expression generation from mruby C
# method registrations and implementations.
require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

root = File.expand_path('..', __dir__)
core_sources = Dir[File.join(root, '3rd/mruby/src/*.c')]
generated = NativeExpressionDevirt.analyze(core_sources)
failures = []
check = lambda do |description, condition|
  puts "  #{condition ? 'ok' : 'FAIL'}  #{description}"
  failures << description unless condition
end

check.call('mruby BasicObject#! is generated from its registered C body',
           generated['!'] == 'mrb_bool_value(!mrb_test(recv))')
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
                        native_expression_devirt: generated)
code = generator.compile_native_primitive_send('!', 1, 'r2', [])
check.call('generated expression is emitted into bc2cpp output',
           code.include?("generated from mruby's registered C implementation") &&
             code.include?('mrb_bool_value(!mrb_test(r2))'))

abort "#{failures.length} native expression devirtualization check(s) failed" unless failures.empty?
