# frozen_string_literal: true

# ROM_GRAPH_PROBE: reads a failed probe link's log (ld --no-demangle) and writes Thumb assembly that defines each
# undefined symbol as a function that hands its name to probe_stub_hit (probe.c) and returns 0.
#   ruby stubs.rb LINK.log > stubs.S
# probe.c defines these itself.
OWN = %w[__dso_handle _init _fini].freeze

names = File.read(ARGV.fetch(0)).scan(/undefined reference to `([^']+)'/).flatten.uniq.sort - OWN
abort "stubs.rb: no undefined reference in #{ARGV[0]}" if names.empty?
puts '.syntax unified', '.thumb'
names.each_with_index do |name, i|
  puts %(.section .rodata.probe_stub_name_#{i},"a"), "probe_stub_name_#{i}: .asciz \"#{name}\""
  puts %(.section .text.probe_stub_#{i},"ax",%progbits), ".globl #{name}", ".type #{name}, %function", '.thumb_func',
       "#{name}:", "  ldr r0, =probe_stub_name_#{i}", '  b probe_stub_hit', '.ltorg'
end
