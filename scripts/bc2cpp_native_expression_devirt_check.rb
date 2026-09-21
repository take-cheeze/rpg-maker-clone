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
check.call('String#bytesize is generated from its public byte-length macro',
           exact_class_expressions['bytesize']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['String', 'mrb_int_value(M, RSTRING_LEN(recv))']])
check.call('Hash#to_hash is generated as an exact-class identity conversion',
           exact_class_expressions['to_hash']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Hash', 'recv']])
check.call('Float#to_f and String/Symbol#to_sym are generated from their C bodies',
           exact_class_expressions['to_f']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Float', 'recv']] &&
             exact_class_expressions['to_sym']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['String', 'mrb_str_intern(M, recv)'], ['Symbol', 'recv']])
check.call('Float#finite? and Float#nan? are generated from their C predicates',
           exact_class_expressions['finite?']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Float', 'mrb_bool_value(isfinite(mrb_float(recv)))']] &&
             exact_class_expressions['nan?']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Float', 'mrb_bool_value(isnan(mrb_float(recv)))']])
check.call('Float#abs preserves the original value unless the C body negates it',
           exact_class_expressions['abs']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Float', '(signbit((mrb_float(recv)))) ? (mrb_float_value(M, -(mrb_float(recv)))) : (recv)']])
check.call('Float#infinite? is generated from its braced conditional C body with a 32-bit-safe +/-1 result',
           exact_class_expressions['infinite?']&.map { |entry| [entry[:owner][:class_name], entry[:arity], entry[:expression]] } ==
             [['Float', 0, '(isinf((mrb_float(recv)))) ? (mrb_fixnum_value((mrb_float(recv)) < 0 ? -1 : 1)) : (mrb_nil_value())']])
check.call('Range#exclude_end? is generated through the public Range exclusion macro',
           exact_class_expressions['exclude_end?']&.map { |entry| [entry[:owner][:class_name], entry[:arity], entry[:expression]] } ==
             [['Range', 0, 'mrb_bool_value(mrb_range_excl_p(M, recv))']])
check.call('a braced early return with extra statements is still declined',
           NativeExpressionDevirt.exact_class_return_expression(
             'if (mrb_float(self) == 0) { mrb_raise(mrb, E_RUNTIME_ERROR, "x"); return mrb_nil_value(); } return mrb_true_value();',
             'mrb', 'self'
           ).nil?)
check.call('Range#begin and Range#end are generated through public Range accessors',
           exact_class_expressions['begin']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Range', 'mrb_range_beg(M, recv)']] &&
             exact_class_expressions['end']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Range', 'mrb_range_end(M, recv)']])
check.call('Hash key predicates are generated with the call-site argument and public lookup helper',
           %w[key? has_key? member?].all? do |name|
             exact_class_expressions[name]&.map { |entry| [entry[:owner][:class_name], entry[:arity]] } == [['Hash', 1]] &&
               exact_class_expressions[name].first[:expression].include?('mrb_hash_key_p(M, recv, (BC2CPP_ARG0))')
           end &&
             exact_class_expressions['include?'].nil? &&
             NativeExpressionDevirt.exact_class_return_expression(
               'return mrb_bool_value(mrb_hash_key_p(mrb, self, mrb_get_arg1(mrb)));', 'mrb', 'self'
             ).nil?)
check.call('Hash#[] is generated from its C wrapper through public mrb_hash_get',
           exact_class_expressions['[]']&.map { |entry| [entry[:owner][:class_name], entry[:arity], entry[:expression]] } ==
             [['Hash', 1, 'mrb_hash_get(M, recv, (BC2CPP_ARG0))']] &&
             NativeExpressionDevirt.exact_class_return_expression(
               'mrb_value key = mrb_get_arg1(mrb); return mrb_hash_get(mrb, self, key);', 'mrb', 'self', arity: 1
             ) == 'mrb_hash_get(M, recv, (BC2CPP_ARG0))')
check.call('Array#at is generated from mruby-array-ext using public integer and element accessors',
           exact_class_expressions['at']&.map { |entry| [entry[:owner][:class_name], entry[:arity]] } == [['Array', 1]] &&
             exact_class_expressions['at'].first[:expression].include?('mrb_ary_entry(recv,') &&
             exact_class_expressions['at'].first[:expression].include?('mrb_as_int(M,') &&
             exact_class_expressions['at'].first[:expression].include?('BC2CPP_ARG0'))
check.call('Hash#__delete preserves the core call-info side effect and public deletion helper',
           exact_class_expressions['__delete']&.map { |entry| [entry[:owner][:class_name], entry[:arity], entry[:expression]] } ==
             [['Hash', 1, '(M->c->ci->mid = 0, mrb_hash_delete_key(M, recv, (BC2CPP_ARG0)))']] &&
             NativeExpressionDevirt.exact_class_return_expression(
               'mrb_value key = mrb_get_arg1(mrb); mrb->c->ci->mid = 0; return mrb_hash_delete_key(mrb, self, key);',
               'mrb', 'self', arity: 1
             ) == '(M->c->ci->mid = 0, mrb_hash_delete_key(M, recv, (BC2CPP_ARG0)))' &&
             NativeExpressionDevirt.exact_class_return_expression(
               'mrb->c->ci->mid = 0; return mrb_hash_delete_key(mrb, self, mrb_get_arg1(mrb));',
               'mrb', 'self'
             ).nil?)
check.call('Array#push derives only the one-argument C fast branch from mruby core',
           exact_class_expressions['push']&.map do |entry|
             [entry[:owner][:class_name], entry[:arity], entry[:expression]]
           end == [['Array', 1, '(mrb_ary_push(M, recv, (BC2CPP_ARG0)), recv)']] &&
             exact_class_expressions['<<']&.map { |entry| [entry[:owner][:class_name], entry[:arity]] } == [['Array', 1]] &&
             NativeExpressionDevirt.exact_array_push_one_argument_expression(
               'mrb_int argc = mrb_get_argc(mrb); if (argc == 1) { mrb_ary_push(mrb, self, mrb_get_argv(mrb)[0]); return self; }',
               'mrb', 'self'
             ) == '(mrb_ary_push(M, recv, (BC2CPP_ARG0)), recv)' &&
             NativeExpressionDevirt.exact_array_push_one_argument_expression(
               'mrb_int argc = mrb_get_argc(mrb); if (argc == 2) { mrb_ary_push(mrb, self, mrb_get_argv(mrb)[0]); return self; }',
               'mrb', 'self'
             ).nil?)
first_body = 'struct RArray *a = mrb_ary_ptr(self); mrb_int size; ' \
             'if (mrb_get_argc(mrb) == 0) { if (ARY_LEN(a) > 0) return ARY_PTR(a)[0]; return mrb_nil_value(); } ' \
             'mrb_get_args(mrb, "|i", &size); return mrb_nil_value();'
last_body = 'struct RArray *a = mrb_ary_ptr(self); mrb_int alen = ARY_LEN(a); ' \
            'if (mrb_get_argc(mrb) == 0) { if (alen > 0) return ARY_PTR(a)[alen - 1]; return mrb_nil_value(); } ' \
            'return mrb_nil_value();'
check.call('Array#first and #last derive only the zero-argument C branch and keep Range accessors',
           exact_class_expressions['first']&.map { |entry| [entry[:owner][:class_name], entry[:arity]] } ==
             [['Array', 0], ['Range', 0]] &&
             exact_class_expressions['last']&.map { |entry| [entry[:owner][:class_name], entry[:arity]] } ==
               [['Array', 0], ['Range', 0]] &&
             exact_class_expressions['first'].first[:expression] ==
               '(ARY_LEN((mrb_ary_ptr(recv))) > 0) ? (ARY_PTR(mrb_ary_ptr(recv))[0]) : (mrb_nil_value())' &&
             exact_class_expressions['last'].first[:expression].include?('ARY_PTR(mrb_ary_ptr(recv))[(ARY_LEN((mrb_ary_ptr(recv)))) - 1]') &&
             exact_class_expressions['first'].last[:expression] == 'mrb_range_beg(M, recv)' &&
             exact_class_expressions['last'].last[:expression] == 'mrb_range_end(M, recv)' &&
             NativeExpressionDevirt.exact_array_no_argument_element_expression(first_body, 'mrb', 'self') ==
               exact_class_expressions['first'].first[:expression] &&
             NativeExpressionDevirt.exact_array_no_argument_element_expression(
               first_body.sub('ARY_PTR(a)[0]', 'mrb_funcall(mrb, self, "x", 0)'), 'mrb', 'self'
             ).nil? &&
             NativeExpressionDevirt.exact_array_no_argument_element_expression(
               first_body.sub('mrb_get_argc(mrb) == 0', 'mrb_get_argc(mrb) == 1'), 'mrb', 'self'
             ).nil?)
check.call('frame-independent public mruby APIs are generated from exact zero-argument registrations',
           exact_class_expressions['clear']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
             [['Array', 'mrb_ary_clear(M, recv)'], ['Hash', 'mrb_hash_clear(M, recv)']] &&
             exact_class_expressions['pop']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['Array', 'mrb_ary_pop(M, recv)']] &&
             %w[keys values].all? do |name|
               exact_class_expressions[name]&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
                 [['Hash', "mrb_hash_#{name}(M, recv)"]]
             end &&
             exact_class_expressions['intern']&.map { |entry| [entry[:owner][:class_name], entry[:expression]] } ==
               [['String', 'mrb_str_intern(M, recv)']] &&
             NativeExpressionDevirt.frame_dependent_body?('mrb_get_args(mrb, "i", &index); return self;') &&
             NativeExpressionDevirt.frame_dependent_body?('mrb->c->ci->mid = 0; return self;'))
check.call('frame-reading C methods are not expression candidates',
           NativeExpressionDevirt.direct_return_expression(
             'mrb_get_args(mrb, "i", &n); return mrb_int_value(mrb, n);', 'mrb', 'self'
           ).nil? &&
             NativeExpressionDevirt.exact_class_return_expression(
               'if (mrb_get_args(mrb, "i", &n)) return mrb_true_value(); return mrb_false_value();', 'mrb', 'self'
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
bytesize_code = generator.compile_native_primitive_send('bytesize', 1, 'r3', [])
check.call('String#bytesize uses an exact String class guard and dynamic fallback',
           bytesize_code.include?('M->string_class') &&
             bytesize_code.include?('mrb_int_value(M, RSTRING_LEN(r3))') &&
             bytesize_code.include?('mrb_funcall(M, r3, "bytesize", 0)'))
hash_key_code = generator.compile_native_primitive_send('key?', 1, 'r3', ['r4'])
check.call('Hash#key? substitutes the original call argument behind an exact Hash guard',
           hash_key_code.include?('M->hash_class') &&
             hash_key_code.include?('mrb_hash_key_p(M, r3, (r4))') &&
             hash_key_code.include?('mrb_funcall(M, r3, "key?", 1, r4)'))
hash_aref_generator = CodeGen.new({}, { '[]' => [MethodDef.new(name: '[]', owner: '<native>', irep: nil,
                                                                 visibility: :public)] }, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                  native_registered_expressions: exact_class_expressions)
hash_aref_code = hash_aref_generator.compile_native_primitive_send('[]', 1, 'r3', ['r4'])
check.call('generated Hash#[] calls the public lookup helper behind an exact Hash guard and keeps fallback',
           hash_aref_code.include?('M->hash_class') && hash_aref_code.include?('mrb_hash_get(M, r3, (r4))') &&
             hash_aref_code.include?('mrb_funcall(M, r3, "[]", 1, r4)'))
array_at_generator = CodeGen.new({}, { 'at' => [MethodDef.new(name: 'at', owner: '<native>', irep: nil,
                                                                 visibility: :public)] }, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                  native_registered_expressions: exact_class_expressions)
array_at_code = array_at_generator.compile_native_primitive_send('at', 1, 'r3', ['r4'])
check.call('generated Array#at uses exact Array identity and keeps fallback dispatch',
           array_at_code.include?('M->array_class') && array_at_code.include?('mrb_ary_entry(r3,') &&
             array_at_code.include?('mrb_as_int(M,') && array_at_code.include?('mrb_funcall(M, r3, "at", 1, r4)'))
hash_delete_generator = CodeGen.new({}, { '__delete' => [MethodDef.new(name: '__delete', owner: '<native>', irep: nil,
                                                                        visibility: :private)] }, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                    native_registered_expressions: exact_class_expressions)
hash_delete_code = hash_delete_generator.compile_native_primitive_send('__delete', 1, 'r3', ['r4'])
check.call('Hash#__delete emits its generated mutation behind the exact Hash guard with dynamic fallback',
           hash_delete_code.include?('M->hash_class') && hash_delete_code.include?('M->c->ci->mid = 0') &&
             hash_delete_code.include?('mrb_hash_delete_key(M, r3, (r4))') &&
             hash_delete_code.include?('mrb_funcall(M, r3, "__delete", 1, r4)'))
array_push_generator = CodeGen.new({}, { 'push' => [MethodDef.new(name: 'push', owner: '<native>', irep: nil,
                                                                  visibility: :public)] }, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                    native_registered_expressions: exact_class_expressions)
array_push_code = array_push_generator.compile_native_primitive_send('push', 1, 'r3', ['r4'])
array_push_wrong_arity = array_push_generator.compile_native_primitive_send('push', 1, 'r3', %w[r4 r5])
check.call('Array#push emits the exact one-argument helper call and keeps multi-argument dispatch',
           array_push_code.include?('M->array_class') && array_push_code.include?('mrb_ary_push(M, r3, (r4))') &&
             array_push_code.include?('), r3);') && array_push_wrong_arity.include?('mrb_funcall(M, r3, "push", 2, r4, r5)') &&
             !array_push_wrong_arity.include?('mrb_ary_push(M, r3,'))
%w[first last].each do |name|
  element_generator = CodeGen.new({}, { name => [MethodDef.new(name: name, owner: '<native>', irep: nil,
                                                               visibility: :public)] }, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                  native_registered_expressions: exact_class_expressions)
  element_code = element_generator.compile_native_primitive_send(name, 1, 'r3', [])
  element_count_code = element_generator.compile_native_primitive_send(name, 1, 'r3', ['r4'])
  check.call("Array##{name} emits the exact Array element path and keeps count-argument dispatch",
             element_code.include?('case MRB_TT_ARRAY:') && element_code.include?('M->array_class') &&
               element_code.include?('ARY_PTR(mrb_ary_ptr(r3))[') && element_code.include?("mrb_funcall(M, r3, \"#{name}\", 0)") &&
               element_count_code.include?("mrb_funcall(M, r3, \"#{name}\", 1, r4)") &&
               !element_count_code.include?('ARY_PTR('))
end
public_api_registry = %w[clear pop keys values intern].to_h do |name|
  [name, [MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)]]
end
public_api_generator = CodeGen.new({}, public_api_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                                   native_registered_expressions: exact_class_expressions)
respond_to_registry = {
  'respond_to?' => [MethodDef.new(name: 'respond_to?', owner: '<native>', irep: nil, visibility: :public)]
}
respond_to_generator = CodeGen.new({}, respond_to_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
respond_to_code = respond_to_generator.compile_native_primitive_send('respond_to?', 1, 'r3', ['r4'])
check.call('respond_to? answers native hits directly and keeps the missing-hook fallback',
           respond_to_code.include?('mrb_obj_to_sym(M, r4)') &&
             respond_to_code.include?('mrb_respond_to(M, r3, bc2cpp_respond_to_id1)') &&
             respond_to_code.include?('mrb_funcall(M, r3, "respond_to?", 1, r4)') &&
             CodeGen::NATIVE_PRIMITIVE_SEND_ARITY['respond_to?'] == 1 &&
             respond_to_generator.native_only_mono?('respond_to?'))
respond_to_override_registry = {
  'respond_to?' => respond_to_registry['respond_to?'] +
    [MethodDef.new(name: 'respond_to?', owner: 'Example', irep: 'Example#respond_to?', visibility: :public)]
}
respond_to_override_generator = CodeGen.new({}, respond_to_override_registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
check.call('a Ruby respond_to? override disables the native-only fast path',
           !respond_to_override_generator.native_only_mono?('respond_to?'))
clear_code = public_api_generator.compile_native_primitive_send('clear', 1, 'r3', [])
pop_code = public_api_generator.compile_native_primitive_send('pop', 1, 'r3', [])
keys_code = public_api_generator.compile_native_primitive_send('keys', 1, 'r3', [])
values_code = public_api_generator.compile_native_primitive_send('values', 1, 'r3', [])
intern_code = public_api_generator.compile_native_primitive_send('intern', 1, 'r3', [])
check.call('generated public C method paths use exact class guards and preserve dynamic fallback',
           clear_code.include?('ARRAY_CLEAR :clear -- generated from mruby core C') &&
             clear_code.include?('mrb_ary_clear(M, r3)') && clear_code.include?('mrb_hash_clear(M, r3)') &&
             pop_code.include?('M->array_class') && pop_code.include?('mrb_ary_pop(M, r3)') &&
             pop_code.include?('mrb_funcall(M, r3, "pop", 0)') &&
             keys_code.include?('mrb_hash_keys(M, r3)') && values_code.include?('mrb_hash_values(M, r3)') &&
             intern_code.include?('mrb_str_intern(M, r3)') &&
             clear_code.include?('mrb_funcall(M, r3, "clear", 0)'))
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
symbol_to_sym_case = symbol_to_sym_code.split('case MRB_TT_SYMBOL:').last.to_s.split('break;').first.to_s
check.call('immediate Float and Symbol paths use type tags without object-pointer dereferences',
           float_to_f_code.include?('case MRB_TT_FLOAT:') && symbol_to_sym_code.include?('case MRB_TT_SYMBOL:') &&
             float_to_f_code.include?('r1 = r3;') && symbol_to_sym_code.include?('r1 = r3;') &&
             float_to_f_code.include?('mrb_funcall(M, r3, "to_f", 0)') &&
             symbol_to_sym_code.include?('mrb_funcall(M, r3, "to_sym", 0)') &&
             !float_to_f_code.include?('mrb_obj_ptr(r3)') && !symbol_to_sym_case.include?('mrb_obj_ptr(r3)'))
finite_code = generator.compile_native_primitive_send('finite?', 1, 'r3', [])
nan_code = generator.compile_native_primitive_send('nan?', 1, 'r3', [])
check.call('Float predicates use their source expressions behind immediate type-tag guards',
           finite_code.include?('case MRB_TT_FLOAT:') && finite_code.include?('isfinite(mrb_float(r3))') &&
             nan_code.include?('case MRB_TT_FLOAT:') && nan_code.include?('isnan(mrb_float(r3))') &&
             finite_code.include?('mrb_funcall(M, r3, "finite?", 0)') &&
             nan_code.include?('mrb_funcall(M, r3, "nan?", 0)'))
abs_code = generator.compile_native_primitive_send('abs', 1, 'r3', [])
check.call('Float#abs uses the recognized conditional C body and keeps dynamic fallback',
           abs_code.include?('case MRB_TT_FLOAT:') && abs_code.include?('signbit((mrb_float(r3)))') &&
             abs_code.include?('mrb_float_value(M, -(mrb_float(r3)))') &&
             abs_code.include?('mrb_funcall(M, r3, "abs", 0)'))
infinite_code = generator.compile_native_primitive_send('infinite?', 1, 'r3', [])
exclude_end_code = generator.compile_native_primitive_send('exclude_end?', 1, 'r3', [])
check.call('Float#infinite? and Range#exclude_end? use immediate/exact-class guards and keep dynamic fallback',
           infinite_code.include?('case MRB_TT_FLOAT:') && infinite_code.include?('isinf((mrb_float(r3)))') &&
             infinite_code.include?('mrb_fixnum_value((mrb_float(r3)) < 0 ? -1 : 1)') &&
             infinite_code.include?('mrb_nil_value()') && !infinite_code.include?('mrb_obj_ptr(r3)') &&
             infinite_code.include?('mrb_funcall(M, r3, "infinite?", 0)') &&
             exclude_end_code.include?('M->range_class') && exclude_end_code.include?('mrb_range_excl_p(M, r3)') &&
             exclude_end_code.include?('mrb_funcall(M, r3, "exclude_end?", 0)'))
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
