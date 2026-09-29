#!/usr/bin/env ruby
# encoding: UTF-8
# Check TYPED_SLOT_INTERPRETED_ACCESS: a typed embedded ivar (mrb_int, mrb_bool,
# mrb_sym) is a raw C field, but the RData ivar descriptor and the GC read a
# slot as an mrb_value. So
#  - a typed ivar touched by a method that stays interpreted is demoted to a
#    plain :value slot;
#  - the descriptor table lists :value slots only.
# A raw 0x10 read as an mrb_value made mrb_gc_mark dereference address 0x10,
# and a raw Integer read by the interpreter crashed optcarrot's PPU.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_typed_slot_check.rb

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class Clock
    def initialize
      @ticks = 0
      @count = 0
    end

    def bump
      @count = @count + 1
    end

    # Fiber.new with a block is refused by bc2cpp, so this stays interpreted.
    def spin
      f = Fiber.new do
        @ticks = @ticks + 1
        Fiber.yield
      end
      f.resume
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'clock.rb')
  File.write(path, FIXTURE)
  ireps, root_label = compile_ireps(path, 'bc2cpp_typed_slot', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  typed = IvarLayout.analyze(ireps, registry)
  layout = IvarLayout.all(ireps, registry).to_h do |klass, ivars|
    [klass, ivars.to_h { |name, fallback| [name, typed.dig(klass, name) || fallback] }]
  end
  check.call('fixture: both ivars are proven typed before the demotion',
             layout.dig('Clock', 'ticks') == :fixnum && layout.dig('Clock', 'count') == :fixnum)

  gen = CodeGen.new(ireps, registry, layout, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
  spin = registry.fetch('spin').find { |d| d.owner == 'Clock' }
  check.call('fixture: Clock#spin does not compile', !gen.compiles_clean?(spin.irep))
  check.call('an ivar touched by an interpreted method becomes a :value slot',
             gen.embed_type('Clock', 'ticks') == :value)
  check.call('an ivar only compiled methods touch stays typed', gen.embed_type('Clock', 'count') == :fixnum)

  structs = gen.emit_structs
  slots = structs[/Clock_ivar_slots\[\] = \{\n(.*?)\n\};/m, 1].to_s
  check.call('the descriptor lists the :value slot', slots.include?('"@ticks"'))
  check.call('the descriptor omits the typed slot', !slots.include?('"@count"'))
  check.call('the descriptor count matches', structs.include?('Clock_ivar_slots, 1, sizeof'))
end

puts '-- rgss:: wrappers need mruby-rgss/src in the build'
Dir.mktmpdir do |dir|
  path = File.join(dir, 'plain.rb')
  File.write(path, "class Plain\n  def go; 1; end\nend\n")
  ireps, root_label = compile_ireps(path, 'bc2cpp_rgss_gate', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  # Array#clear from mruby core registers the same name as RGSS::Bitmap#clear.
  registry['clear'] << MethodDef.new(name: 'clear', owner: '<native>', irep: nil, visibility: :public)
  build = lambda do |sources|
    CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new,
                nil, nil, { 'clear' => sources })
  end
  check.call('core-only natives do not select the RGSS Bitmap#clear wrapper',
             !build.call(['3rd/mruby/src/array.c']).native_wrapper_owner_safe?('clear', 'RGSS::Bitmap'))
  check.call('an mruby-rgss/src registration does',
             build.call(['mruby-rgss/src/lib.cxx']).native_wrapper_owner_safe?('clear', 'RGSS::Bitmap'))
end

abort "#{failures.size} check(s) failed" unless failures.empty?
puts 'ok'
