# frozen_string_literal: true

# Generates the no-Float (MRB_NO_FLOAT) copy of an mruby-rpg2k mrblib file. A block between
# "# FLOAT-BEGIN <name>" and "# FLOAT-END <name>" is replaced by its no-Float form below, indented to the
# marker. The Float build keeps the source as it is. The output is checked to hold no Float literal, no
# .to_f, no Math call and no 'E' unpack, since a no-Float VM cannot run any of them.
#
# Usage: ruby gen_rpg2k_nofloat.rb <src.rb> <out.rb>

SRC = ARGV.fetch(0)
OUT = ARGV.fetch(1)

# sin(phase * PI / 128) * 1024 for phase 0..255, each stored as its value + 1024 in four digits, so the shake
# lookup is a plain integer. Computed here, on the host, and written out as a literal.
SINE_TABLE = (0...256).map { |i| format('%04d', (Math.sin(i * Math::PI / 128) * 1024).round + 1024) }.join

REPLACEMENTS = {
  # RPG2000 EXP curve in 2**32 fixed point (4_294_967_296 is the unit). Differs from the Float loop only where the
  # Float rounding does.
  'exp' => [
    'base = db_exp_param(:exp_basic) * 4_294_967_296',
    'inflation = (150 + db_exp_param(:exp_increase)) * 4_294_967_296 / 100',
    'correction = db_exp_param(:exp_correction) * 4_294_967_296',
    'result = 0',
    'n.times do',
    '  result += (correction + base) / 4_294_967_296',
    '  base = base * inflation / 4_294_967_296',
    '  inflation = ((n + 1) * 2 + 800) * (inflation - 4_294_967_296) / 1000 + 4_294_967_296',
    'end'
  ],
  # Shake: amplitude * sin(phase) truncated toward zero, the sine from SINE_TABLE (scaled by 1024).
  'shake' => [
    "shake_fx = -amplitude * (\"#{SINE_TABLE}\"[phase * 4, 4].to_i - 1024)",
    'newpos = shake_fx < 0 ? -((-shake_fx) / 1024) : shake_fx / 1024'
  ],
  # Tint steps toward its target by a rounded whole-unit share each frame. The no-Float build does not keep the
  # Float build's fractional progress.
  'tint' => [
    'dr = @tr - @r; @r += dr < 0 ? -((-dr + (@frames >> 1)) / @frames) : (dr + (@frames >> 1)) / @frames',
    'dg = @tg - @g; @g += dg < 0 ? -((-dg + (@frames >> 1)) / @frames) : (dg + (@frames >> 1)) / @frames',
    'db = @tb - @b; @b += db < 0 ? -((-db + (@frames >> 1)) / @frames) : (db + (@frames >> 1)) / @frames',
    'ds = @tsat - @sat; @sat += ds < 0 ? -((-ds + (@frames >> 1)) / @frames) : (ds + (@frames >> 1)) / @frames'
  ],
  # The wave transition needs Float arguments in its native blit, so no-Float runs the plain transition instead.
  'wave' => ['false'],
  'wave_phase' => ['phase = 0 # the wave transition is off in the no-Float build (see wave?)'],
  # Save doubles are fixed-point in the no-Float build (LCF.double_*), so the timestamp is already fixed.
  'timestamp' => ['title[1] = timestamp'],
  'flash_power' => ['hero[84] = pf[:power] * 1024 * pf[:frames] / total'],
  'flash_level' => ['level = (hero[:flash_current_level] || 0) >> 10'],
  'clock_sentinel' => ['NO_CLOCK_TIMESTAMP = 37_402_624 # 36526 * 1024: 2000-01-01 in 1/1024 days'],
  # The save clock has 1/1024-day resolution (about 84 seconds) in the no-Float build.
  'ole_now' => ['Time.now.to_i * 1024 / 86400 + OLE_EPOCH_OFFSET * 1024'],
  # A legacy double field read as a whole number (the power of a shake or flash).
  'ext_double' => ['LCF.unpack_fixed_double(raw, 10) / 1024']
}.freeze

lines = File.read(SRC).lines
out = []
used = []
i = 0
while i < lines.size
  line = lines[i]
  m = line.match(/^(\s*)# FLOAT-BEGIN (\S+)\s*$/)
  unless m
    raise "gen_rpg2k_nofloat: # FLOAT-END without a BEGIN at #{SRC}:#{i + 1}" if line =~ /^\s*# FLOAT-END /
    out << line
    i += 1
    next
  end
  indent, name = m[1], m[2]
  repl = REPLACEMENTS.fetch(name) { raise "gen_rpg2k_nofloat: no no-Float form for block #{name} in #{SRC}" }
  close = i + 1
  close += 1 while close < lines.size && lines[close] !~ /^\s*# FLOAT-END #{Regexp.escape(name)}\s*$/
  raise "gen_rpg2k_nofloat: no FLOAT-END #{name} in #{SRC}" if close >= lines.size
  repl.each { |r| out << "#{indent}#{r}\n" }
  used << name
  i = close + 1
end

text = out.join
bad = text.lines.reject { |l| l.lstrip.start_with?('#') }
  .select { |l| l =~ /(?<![\w.])\d+\.\d+(?:e[-+]?\d+)?(?![\w.])|\.to_f\b|\bMath\b|\bunpack\('E'\)/ }
unless bad.empty?
  warn "gen_rpg2k_nofloat: Float use left in the no-Float output of #{SRC}:"
  bad.each { |l| warn "  #{l.strip}" }
  exit 1
end

File.write(OUT, text)
warn "gen_rpg2k_nofloat: wrote #{OUT} (#{used.size} block(s): #{used.join(', ')})"
