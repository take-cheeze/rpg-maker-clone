#!/usr/bin/env ruby
# frozen_string_literal: true

# Every mruby-rpg2k mrblib file that a no-Float (MRB_NO_FLOAT) build can run must hold no Float outside its
# FLOAT-BEGIN/END blocks, and every file with such a block must generate a no-Float copy that holds none
# (see mruby-rpg2k/gen_rpg2k_nofloat.rb, which mruby-rpg2k/mrbgem.rake runs for the no-Float build).
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
MRBLIB = File.join(ROOT, 'mruby-rpg2k', 'mrblib')
GEN = File.join(ROOT, 'mruby-rpg2k', 'gen_rpg2k_nofloat.rb')
FLOAT_USE = /(?<![\w.])\d+\.\d+(?:e[-+]?\d+)?(?![\w.])|\.to_f\b|\bMath\b|\bunpack\('E'\)/.freeze

failures = []
checked = 0
Dir.glob(File.join(MRBLIB, '**', '*.rb')).sort.each do |path|
  rel = path.delete_prefix("#{MRBLIB}/")
  checked += 1
  text = File.read(path)
  if text.include?('# FLOAT-BEGIN ')
    Dir.mktmpdir do |dir|
      out = File.join(dir, 'out.rb')
      _, err, status = Open3.capture3('ruby', GEN, path, out)
      if status.success?
        generated = File.read(out)
        failures << "#{rel}: generated copy still has FLOAT-BEGIN/END markers" if generated.include?('# FLOAT-')
      else
        failures << "#{rel}: generator failed: #{err.strip}"
      end
    end
  else
    # Outside any block, a file must hold no Float use: the no-Float build compiles it as it is.
    text.lines.each_with_index do |line, i|
      next if line.lstrip.start_with?('#')
      failures << "#{rel}:#{i + 1}: Float use with no no-Float form: #{line.strip}" if line =~ FLOAT_USE
    end
  end
end

if failures.empty?
  puts "rpg2k no-Float wiring check: #{checked} mrblib file(s) checked, no Float left in the no-Float build"
else
  warn failures.join("\n")
  warn "rpg2k no-Float wiring check: #{failures.size} problem(s)"
  exit 1
end
