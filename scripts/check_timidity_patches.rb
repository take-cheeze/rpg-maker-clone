#!/usr/bin/env ruby
# Verify the bundled MIDI patch set is internally consistent.
#
# assets/timidity/timidity.cfg names a GUS patch (.pat) per General MIDI program
# and drum note. SDL_mixer's TiMidity resolves those names relative to the
# config file's own directory and simply skips an instrument whose file is
# missing — quietly, at play time, as a thinner-sounding track rather than an
# error. A patch dropped by a bad copy or an over-eager .gitignore would
# therefore ship unnoticed, so check every reference up front.
#
# Usage: ruby scripts/check_timidity_patches.rb [assets/timidity]

require 'set'

dir = ARGV[0] || File.expand_path('../assets/timidity', __dir__)
cfg = File.join(dir, 'timidity.cfg')

# The patch set is downloaded, not committed (scripts/download-freepats.bash),
# so its absence is a normal state for a fresh checkout rather than a failure.
# Report it and pass; there is nothing to be inconsistent with.
unless File.file?(cfg)
  puts "timidity: no patch set in #{dir} — skipping " \
       '(run scripts/download-freepats.bash to install it)'
  exit 0
end

referenced = []
section = nil
File.foreach(cfg).with_index(1) do |line, lineno|
  line = line.sub(/#.*/, '').strip
  next if line.empty?

  # "drumset N" / "bank N" open a section; instrument lines are "<no> <file> ..."
  case line
  when /\A(drumset|bank)\s+(\d+)\z/
    section = "#{Regexp.last_match(1)} #{Regexp.last_match(2)}"
    next
  end

  fields = line.split(/\s+/)
  next if fields.size < 2
  # Skip TiMidity directives that are not instrument definitions.
  next unless fields[0] =~ /\A\d+\z/

  referenced << { file: fields[1], line: lineno, section: section }
end

abort "#{cfg}: no instruments referenced" if referenced.empty?

missing = referenced.reject { |r| File.file?(File.join(dir, r[:file])) }
empty = referenced.select do |r|
  path = File.join(dir, r[:file])
  File.file?(path) && File.size(path).zero?
end

# Patches present on disk but never referenced are dead weight in the bundle.
on_disk = Dir.glob(File.join(dir, '**', '*.pat')).map { |p| p.sub("#{dir}/", '') }
unreferenced = on_disk.to_set - referenced.map { |r| r[:file] }.to_set

missing.each do |r|
  warn "#{cfg}:#{r[:line]}: [#{r[:section]}] missing patch #{r[:file]}"
end
empty.each do |r|
  warn "#{cfg}:#{r[:line]}: [#{r[:section]}] empty patch #{r[:file]}"
end
unreferenced.sort.each { |f| warn "#{dir}: #{f} is not referenced by timidity.cfg" }

if missing.empty? && empty.empty? && unreferenced.empty?
  total = referenced.map { |r| File.size(File.join(dir, r[:file])) }.sum
  puts format('timidity: %d instruments, %d files, %.1f MiB — OK',
              referenced.size, on_disk.size, total / 1024.0 / 1024.0)
  exit 0
end

abort 'timidity patch set is inconsistent'
