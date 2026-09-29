#!/usr/bin/env ruby
# frozen_string_literal: true

# Every hunk of patches/mruby-*.patch must carry context lines.
#
# `patch` places a zero-context hunk (`@@ -N,0 +M,K @@`) purely by line number,
# so it silently lands in the wrong spot as soon as an earlier patch in the
# chain shifts the file. mruby-rdata-ivar-slots.patch did exactly that in CI:
# the GC-marking block for RData ivar slots ended up inside the CLASS case of
# gc_mark_children, never ran, and the freed ivar values crashed optcarrot
# (`undefined method '>=' for <blank>`).

require 'pathname'

ROOT = Pathname.new(__dir__).parent
HUNK = /\A@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@/

failures = []
Dir[ROOT.join('patches/mruby-*.patch').to_s].sort.each do |path|
  file = nil
  File.foreach(path, chomp: true) do |line|
    file = Regexp.last_match(1) if line =~ %r{\A\+\+\+ b/(.+)}
    next unless (match = HUNK.match(line))
    next unless match[2] == '0'

    failures << "#{File.basename(path)}: #{file}: zero-context hunk #{line[/\A@@[^@]*@@/]}"
  end
end

# The GC hunk must anchor on the CDATA case, not just any context.
rdata = File.read(ROOT.join('patches/mruby-rdata-ivar-slots.patch'))
gc_hunk = rdata[%r{^\+\+\+ b/src/gc\.c\n(.*?)(?=^--- a/)}m, 1].to_s
unless gc_hunk.include?(" case MRB_TT_CDATA:\n+    if (obj->tt == MRB_TT_CDATA) {")
  failures << 'mruby-rdata-ivar-slots.patch: gc.c marking block must directly follow `case MRB_TT_CDATA:`'
end

if failures.empty?
  puts 'mruby patch context check: ok'
else
  warn failures
  exit 1
end
