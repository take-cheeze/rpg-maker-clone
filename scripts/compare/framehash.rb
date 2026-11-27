#!/usr/bin/env ruby
# frozen_string_literal: true

# FRAMEHASH: compares the "FH <frame> <hash>" lines of two runs, which draw the same frames exactly when the lines are
# equal. A run is a file (a Renode run's scripts/wio/renode_game.bash --framehash FILE, or the stdout of a host run with
# BC2CPP_HOST_FRAMEHASH=1) or a directory of them (a host sweep's logs), compared by file name. Hashes are of the
# platform's own framebuffer, so compare a Renode run with a Renode run and a host run with a host run.
#
#   ruby scripts/compare/framehash.rb [--min-distinct N] A B
#
# Prints one line per file and fails on a differing frame, a file only one side has, a run with no FH line, or (with
# --min-distinct) a run that shows fewer than N different pictures.
require 'optparse'

min_distinct = 1
OptionParser.new do |o|
  o.banner = 'usage: framehash.rb [--min-distinct N] A B'
  o.on('--min-distinct N', Integer) { |v| min_distinct = v }
end.parse!
abort 'usage: framehash.rb [--min-distinct N] A B' unless ARGV.size == 2

def hashes(path)
  File.foreach(path, encoding: 'BINARY').filter_map do |line|
    m = line.match(/\AFH (\d+) (\h+)\s*\z/)
    m && [Integer(m[1]), m[2]]
  end
end

a, b = ARGV
pairs = if File.directory?(a) && File.directory?(b)
          names = (Dir.children(a) + Dir.children(b)).uniq.sort.select do |n|
            File.file?(File.join(a, n)) || File.file?(File.join(b, n))
          end
          names.map { |n| [n, File.join(a, n), File.join(b, n)] }
        elsif File.file?(a) && File.file?(b)
          [[File.basename(a), a, b]]
        else
          abort "framehash: #{a} and #{b} must both be files or both directories"
        end

failed = 0
same = 0
pairs.each do |name, pa, pb|
  unless File.file?(pa) && File.file?(pb)
    puts "MISSING #{name}: only in #{File.file?(pa) ? a : b}"
    failed += 1
    next
  end
  ha = hashes(pa)
  hb = hashes(pb)
  # A directory may hold logs that are not FH runs (a sweep's own summaries).
  next if ha.empty? && hb.empty? && pairs.size > 1

  if ha.empty? || hb.empty?
    puts "EMPTY #{name}: no FH line in #{ha.empty? ? pa : pb}"
    failed += 1
  elsif ha != hb
    first = ha.zip(hb).index { |x, y| x != y } || [ha.size, hb.size].min
    at = ha[first] || hb[first]
    puts "DIFF #{name}: #{ha.size} vs #{hb.size} frames, first difference at line #{first + 1} (frame #{at[0]}: " \
         "#{ha[first]&.last || '-'} vs #{hb[first]&.last || '-'})"
    failed += 1
  elsif (distinct = ha.map(&:last).uniq.size) < min_distinct
    puts "FLAT #{name}: #{distinct} different pictures in #{ha.size} frames, expected #{min_distinct}"
    failed += 1
  else
    puts "same #{name}: #{ha.size} frames, #{distinct} different pictures"
    same += 1
  end
end
puts "framehash: #{same} same, #{failed} failed"
exit(failed.zero? ? 0 : 1)
