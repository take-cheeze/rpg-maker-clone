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
exact_class_expressions = NativeExpressionDevirt.analyze_exact_class_expressions(core_sources)
failures = []
check = lambda do |description, condition|
  puts "  #{condition ? 'ok' : 'FAIL'}  #{description}"
  failures << description unless condition
end

check.call('mruby BasicObject#! is generated from its registered C body',
           generated['!'] == 'mrb_bool_value(!mrb_test(recv))')
check.call('Array and Hash size bodies are generated; String size is declined',
           exact_class_expressions['size']&.map { |entry| entry[:owner][:class_name] } == %w[Array Hash] &&
             exact_class_expressions['size'].none? { |entry| entry[:expression].include?('RSTRING_CHAR_LEN') })
check.call('Array and Hash length bodies are generated while String length is declined',
           exact_class_expressions['length']&.map { |entry| entry[:owner][:class_name] } == %w[Array Hash] &&
             exact_class_expressions['length'].none? { |entry| entry[:owner][:class_name] == 'String' })
check.call('Array, Hash, and String empty? bodies are generated from their C implementations',
           exact_class_expressions['empty?']&.map { |entry| entry[:owner][:class_name] } == %w[Array Hash String])
check.call('Hash#to_hash is generated as an exact-class identity conversion',
           exact_class_expressions['to_hash']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Hash', 'recv']])
check.call('Float#to_f and Symbol#to_sym are generated from the shared C identity body',
           exact_class_expressions['to_f']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Float', 'recv']] &&
             exact_class_expressions['to_sym']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Symbol', 'recv']])
check.call('Float#finite? and Float#nan? are generated from their C predicates',
           exact_class_expressions['finite?']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Float', 'mrb_bool_value(isfinite(mrb_float(recv)))']] &&
             exact_class_expressions['nan?']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Float', 'mrb_bool_value(isnan(mrb_float(recv)))']])
check.call('Range#begin and Range#end are generated through public Range accessors',
           exact_class_expressions['begin']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Range', 'mrb_range_beg(M, recv)']] &&
             exact_class_expressions['end']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Range', 'mrb_range_end(M, recv)']])
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
                        native_registered_expressions: exact_class_expressions)
code = generator.compile_native_primitive_send('!', 1, 'r2', [])
check.call('generated expression is emitted into bc2cpp output',
           code.include?("generated from mruby's registered C implementation") &&
             code.include?('mrb_bool_value(!mrb_test(r2))'))
size_code = generator.compile_native_primitive_send('size', 1, 'r3', [])
check.call('exact-class output uses generated C expressions and falls back for other receiver classes',
           size_code.include?('M->array_class') && size_code.include?('M->hash_class') &&
             size_code.include?('mrb_funcall(M, r3, "size", 0)'))
length_code = generator.compile_native_primitive_send('length', 1, 'r3', [])
check.call('Array/Hash length is generated from the same C expressions as size',
           length_code.include?('M->array_class') && length_code.include?('M->hash_class') &&
             length_code.include?('mrb_funcall(M, r3, "length", 0)'))
begin_code = generator.compile_native_primitive_send('begin', 1, 'r3', [])
end_code = generator.compile_native_primitive_send('end', 1, 'r3', [])
check.call('Range accessors use an exact Range class guard and dynamic fallback',
           begin_code.include?('M->range_class') && begin_code.include?('mrb_range_beg(M, r3)') &&
             begin_code.include?('mrb_funcall(M, r3, "begin", 0)') &&
             end_code.include?('M->range_class') && end_code.include?('mrb_range_end(M, r3)') &&
             end_code.include?('mrb_funcall(M, r3, "end", 0)'))
hash_to_hash_code = generator.compile_native_primitive_send('to_hash', 1, 'r3', [])
check.call('generated Hash#to_hash is exact-class guarded and preserves dynamic fallback',
           hash_to_hash_code.include?('M->hash_class') &&
             hash_to_hash_code.include?('r1 = r3;') &&
             hash_to_hash_code.include?('mrb_funcall(M, r3, "to_hash", 0)'))
float_to_f_code = generator.compile_native_primitive_send('to_f', 1, 'r3', [])
symbol_to_sym_code = generator.compile_native_primitive_send('to_sym', 1, 'r3', [])
check.call('immediate Float and Symbol fast paths use type tags without object-pointer dereferences',
           float_to_f_code.include?('case MRB_TT_FLOAT:') && symbol_to_sym_code.include?('case MRB_TT_SYMBOL:') &&
             float_to_f_code.include?('r1 = r3;') && symbol_to_sym_code.include?('r1 = r3;') &&
             float_to_f_code.include?('mrb_funcall(M, r3, "to_f", 0)') &&
             symbol_to_sym_code.include?('mrb_funcall(M, r3, "to_sym", 0)') &&
             !float_to_f_code.include?('mrb_obj_ptr(r3)') && !symbol_to_sym_code.include?('mrb_obj_ptr(r3)'))
finite_code = generator.compile_native_primitive_send('finite?', 1, 'r3', [])
nan_code = generator.compile_native_primitive_send('nan?', 1, 'r3', [])
check.call('Float predicates use their source expressions behind immediate type-tag guards',
           finite_code.include?('case MRB_TT_FLOAT:') && finite_code.include?('isfinite(mrb_float(r3))') &&
             nan_code.include?('case MRB_TT_FLOAT:') && nan_code.include?('isnan(mrb_float(r3))') &&
             finite_code.include?('mrb_funcall(M, r3, "finite?", 0)') &&
             nan_code.include?('mrb_funcall(M, r3, "nan?", 0)'))
override_registry = {
  'size' => [
    MethodDef.new(name: 'size', owner: '<native>', irep: nil, visibility: :public),
    MethodDef.new(name: 'size', owner: 'Array', irep: 'Array#size', visibility: :public)
  ]
}
override_generator = CodeGen.new({}, override_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                 native_registered_expressions: exact_class_expressions)
check.call('a Ruby override on a built-in container rejects generated native bodies',
           !override_generator.builtin_class_send_safe?('size', %w[Array Hash String]))
float_override_registry = {
  'to_f' => [
    MethodDef.new(name: 'to_f', owner: '<native>', irep: nil, visibility: :public),
    MethodDef.new(name: 'to_f', owner: 'Float', irep: 'Float#to_f', visibility: :public)
  ]
}
float_override_generator = CodeGen.new({}, float_override_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                       native_registered_expressions: exact_class_expressions)
check.call('a Ruby Float#to_f override rejects the generated immediate-type path',
           !float_override_generator.builtin_class_send_safe?('to_f', %w[Float]))
range_override_registry = {
  'begin' => [
    MethodDef.new(name: 'begin', owner: '<native>', irep: nil, visibility: :public),
    MethodDef.new(name: 'begin', owner: 'Range', irep: 'Range#begin', visibility: :public)
  ]
}
range_override_generator = CodeGen.new({}, range_override_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                       native_registered_expressions: exact_class_expressions)
check.call('a Ruby Range#begin override rejects the generated accessor',
           !range_override_generator.builtin_class_send_safe?('begin', %w[Range]))

abort "#{failures.length} native expression devirtualization check(s) failed" unless failures.empty?
