#!/usr/bin/env ruby
# frozen_string_literal: true
#
# HOST_ARENA: every host that drives the game from C restores the GC arena
# around its per-frame call and its construction of the game. An entry call
# leaves its result in the arena (mrb_funcall's contract), so a frame loop
# without the restore grows the arena by a slot per frame and keeps whatever
# those slots name alive for the whole run.
#
# For each call site below, the nearest mrb_gc_arena_save before it must be
# restored, with the same index, after it and before the function ends.
# scripts/bc2cpp/trace_host.cxx also fails a run whose main_loop leaves more
# than its result in the arena, which covers the generated entry itself.
#
# Usage: ruby scripts/bc2cpp-rpg/host_arena_check.rb

require_relative '../../tools/bc2cpp/world_root'

ROOT = BC2CPP_WORLD_ROOT
FRAME = /bc2cpp_entry_\w+_main_loop\(|game_info->main_loop\(|mrb_funcall\(\w+, \w+, "main_loop"/
BOOT = /bc2cpp_entry_RPG2k_new\(|game_info->make\(|mrb_obj_new\(M, mrb_class_get\(M, "RPG2k"\)/
HOSTS = {
  'app/wio/src/wio_renode_game_main.cxx' => [FRAME, BOOT],
  'app/wio/src/maix_game_main.cxx' => [FRAME, BOOT],
  'app/psp/main.cxx' => [FRAME, BOOT],
  'src/main.cxx' => [FRAME, BOOT],
  'scripts/bc2cpp/trace_host.cxx' => [FRAME, BOOT]
}.freeze
SAVE = /\b(\w+) = (?:[^;]*\? )?mrb_gc_arena_save\(/

# The problems with the call sites `pattern` matches in `lines`; [] when each one is restored.
def unrestored(lines, pattern)
  sites = lines.each_index.select { |i| lines[i].match?(pattern) && !lines[i].lstrip.start_with?('//') }
  return ['no call site found'] if sites.empty?

  sites.filter_map do |i|
    start = i.downto(0).find { |j| lines[j].match?(/\A[^\s}#]/) } || 0
    finish = (i...lines.size).find { |j| lines[j].start_with?('}') } || lines.size
    save = i.downto(start).find { |j| lines[j].match?(SAVE) }
    next "line #{i + 1}: no mrb_gc_arena_save before the call" unless save

    var = lines[save][SAVE, 1]
    next nil if lines[(i + 1)...finish].any? { |l| l.match?(/mrb_gc_arena_restore\(\w+, #{var}\)/) }

    "line #{i + 1}: #{var} (saved on line #{save + 1}) is not restored after the call"
  end
end

failures = []
check = lambda do |label, problems|
  puts "  #{problems.empty? ? 'ok  ' : 'FAIL'} #{label}"
  problems.each { |p| puts "         #{p}" }
  failures << label unless problems.empty?
end

puts '-- the check itself'
leaky = <<~CPP.lines
  void loop(void) {
    const int ai = mrb_gc_arena_save(g_mrb);
    mrb_gc_arena_restore(g_mrb, ai);
    bc2cpp_entry_RPG2k_main_loop(g_mrb, g_game);
  }
CPP
unsaved = ["void loop(void) {\n", "  game_info->main_loop(M, g);\n", "}\n"]
check.call('a restore before the call does not count', unrestored(leaky, FRAME).empty? ? ['it passed'] : [])
check.call('a frame loop with no save fails', unrestored(unsaved, FRAME).empty? ? ['it passed'] : [])
restored = <<~CPP.lines
  void loop(void) {
    const int ai = g_mrb ? mrb_gc_arena_save(g_mrb) : 0;
    bc2cpp_entry_RPG2k_main_loop(g_mrb, g_game);
    mrb_gc_arena_restore(g_mrb, ai);
  }
CPP
check.call('a restored frame loop passes', unrestored(restored, FRAME))

puts '-- hosts'
HOSTS.each do |path, patterns|
  lines = File.readlines(File.join(ROOT, path))
  check.call("#{path}: the frame call", unrestored(lines, patterns[0]))
  check.call("#{path}: the construction", unrestored(lines, patterns[1]))
end

if failures.empty?
  puts 'host arena check: PASS'
else
  warn "host arena check: #{failures.size} failure(s)"
  exit 1
end
