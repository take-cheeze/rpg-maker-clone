#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_CLASS_SUPERS (tools/bc2cpp/core_enumerator_free.rb, native_class_supers): the superclass of a class the natives
# create. A superclass passed as a local variable resolves through the file's class bindings, so mruby-io's
# `File < IO` (`io = mrb_class_get_id(mrb, MRB_SYM(IO))`) reaches the singleton ancestors and `File.open` finds
# IO.singleton#open. A variable bound to no class stays unresolved, so a lookup through it is not answered as "none".
# Host-only: no mrbc needed.
#
#   ruby scripts/bc2cpp/native_class_supers_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/core_enumerator_free'
require_relative '../../tools/bc2cpp/core_enumerator_types'

checks = 0
failures = []
check = lambda do |label, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless condition
end

identity = ->(text) { text }
supers_of = lambda do |source|
  Dir.mktmpdir('native_class_supers') do |dir|
    path = File.join(dir, 'native.c')
    File.write(path, source)
    CoreEnumeratorFree.send(:native_class_supers, [path], strip: identity)
  end
end

puts '== a superclass held in a local variable'
bound = supers_of.call(<<~C)
  void mrb_init_fixture(mrb_state *mrb) {
    struct RClass *io   = mrb_class_get_id(mrb, MRB_SYM(IO));
    struct RClass *file = mrb_define_class_id(mrb, MRB_SYM(File), io);
    struct RClass *io2  = mrb_define_class_id(mrb, MRB_SYM(IO), mrb->object_class);
  }
C
check.call('File resolves to IO through the bound variable', bound['File'] == 'IO')
check.call('IO keeps its object_class superclass (Object)', bound['IO'] == 'Object')

puts '== an unbound variable and a literal superclass'
unbound = supers_of.call(<<~C)
  void mrb_init_fixture(mrb_state *mrb) {
    struct RClass *thing = mrb_define_class_id(mrb, MRB_SYM(Thing), some_unknown);
  }
C
check.call('an unbound superclass variable stays unresolved (nil)', unbound.key?('Thing') && unbound['Thing'].nil?)

puts '== the singleton chain reaches the inherited class method'
hierarchy = lambda do |supers|
  CoreEnumeratorTypes::Hierarchy.new(superclass_of: {}, included: {}, prepended: {}, unknown: Set.new, modules: Set.new,
                                     definers: { 'IO.singleton' => Set['open'] }, computed: Set.new,
                                     native_classes: supers.merge('IO' => 'Object'))
end
resolved = hierarchy.call(bound.reject { |k, _| k == 'IO' })
check.call('File.singleton lists IO.singleton among its ancestors',
           resolved.ancestors('File.singleton').include?('IO.singleton'))
check.call('File.open resolves to IO.singleton', resolved.lookup('File.singleton', 'open') == 'IO.singleton')

puts '== the real mruby-io sources (when the mruby submodule is checked out)'
io_sources = Dir[File.expand_path('../../3rd/mruby/mrbgems/mruby-io/src/*.c', __dir__)]
if io_sources.empty?
  puts '  skip mruby-io sources not checked out'
else
  real = CoreEnumeratorFree.send(:native_class_supers, io_sources, strip: identity)
  check.call('mruby-io File < IO', real['File'] == 'IO')
end

puts "native_class_supers_check: #{checks} checks"
unless failures.empty?
  warn "native_class_supers_check: #{failures.size} of #{checks} checks failed"
  exit 1
end
puts 'native_class_supers_check: all checks passed'
