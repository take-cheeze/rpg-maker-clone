#!/usr/bin/env ruby
# frozen_string_literal: true

# PRESYM_NAMES (scripts/native/presym_names.rb): the rewrite on small cases, and no literal-name lookup left in the
# engine's native sources.
require_relative 'presym_names'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
rewrite = ->(src) { PresymNames.rewrite(src) }

check.call('an ivar, a predicate and a setter',
           rewrite.('a(M, mrb_intern_lit(M, "@x")); b(mrb_intern_lit(M, "empty?"), mrb_intern_cstr(M, "x="));') ==
           'a(M, MRB_IVSYM(x)); b(MRB_SYM_Q(empty), MRB_SYM_E(x));')
check.call('an operator', rewrite.('mrb_funcall(M, v, "==", 1, w)') == 'mrb_funcall_id(M, v, MRB_OPSYM(eq), 1, w)')
check.call('nested class lookups',
           rewrite.('mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect")') ==
           'mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Rect))')
check.call('a ternary between two names',
           rewrite.('mrb_funcall(M, i, p ? "press" : "release", 1, k)') ==
           'mrb_funcall_id(M, i, p ? MRB_SYM(press) : MRB_SYM(release), 1, k)')
kept = ['mrb_intern_cstr(M, name)', 'mrb_intern_lit(M, "a b")', 'mrb_module_get(M, "rgss")',
        'mrb_const_set(M, m, mrb_intern_lit(M, "_zobjs"), v)', 'mrb_define_method(M, c, "x", f, a)',
        "RClass* r = mrb_module_get(M, \"RGSS\");\nmrb_define_module_under(M, r, \"Audio\");"]
kept.each { |src| check.call("kept: #{src.lines.first.strip}", rewrite.(src) == src) }

PresymNames.files([]).each do |path|
  src = File.read(path)
  check.call("#{path.delete_prefix("#{PresymNames::ROOT}/")} has no literal-name lookup", PresymNames.rewrite(src) == src)
end
abort "presym_names_check: #{failures.size} failed" unless failures.empty?
puts 'presym_names_check: ok'
