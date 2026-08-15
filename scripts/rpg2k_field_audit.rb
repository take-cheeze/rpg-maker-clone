#!/usr/bin/env ruby
# encoding: UTF-8
#
# Which database fields the real games *set* that the runtime never *reads*.
#
# This is a survey, not a check: it always exits 0 and asserts nothing. It exists
# because the same question kept producing the next piece of work. A field the
# schema parses and the runtime never mentions is a feature the author paid for
# and the player does not get, and the count of rows that set it away from its
# default is a decent proxy for how much of the game that is.
#
# Every RPG2000 defect found by this method was invisible to the fixture suites,
# for one reason each time: the fixtures encoded the same assumption as the code,
# because they were written to match it. Only a real game's tables disagree.
# See docs/adr/0031 (item and skill types), 0032 (state effects), 0033
# (equipment), 0034 (terrain), 0035 (bush depth) and 0036 (the battle log).
#
# Usage:
#   ruby scripts/rpg2k_field_audit.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories containing an RPG_RT.ldb.
#
# Reading the output. "the runtime never names" is a **substring search of the
# runtime source for the field name**, which is deliberately crude in one
# direction: a name that appears only in a comment counts as named, so the list
# under-reports. It never over-reports — a field it lists really is absent from
# the source. Treat a hit as "worth looking at", not as a defect: check the
# NOT_OURS table below first, then read what RPG_RT actually does with the field
# before writing anything.

require 'stringio'

module LCF
  # uni-algo stand-in, as in scripts/lcf_testbed_check.rb. Only field presence
  # and counts are reported, so the shim never affects the result.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{fffd}")
  end

  def utf8_to_cp932(s)
    s.dup.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

ROOT = File.expand_path('..', __dir__)
load File.join(ROOT, 'mruby-lcf/mrblib/lcf.rb')
load File.join(ROOT, 'mruby-lcf/mrblib/schema.rb')

# Fields this runtime should **not** grow, with the reason, so nobody spends an
# afternoon rediscovering it. Each was checked against EasyRPG rather than
# guessed at, and each would otherwise sit near the top of the list below.
NOT_OURS = {
  levitate: 'RPG2003 only — EasyRPG\'s Game_Enemy::GetFlyingOffset returns 0 ' \
            'outside 2k3: "2k does not support flying, albeit mentioned in ' \
            'the help file"',
  message_affected: 'no known trigger — EasyRPG defines ' \
                    'GetStateAffectedMessage and never calls it from either ' \
                    'battle scene, so nothing pins when RPG_RT prints it',
  actor_critical: 'side-keying unresolved — EasyRPG picks it when the ' \
                  '*target* is an ally, while 会心 / 痛恨 read as keyed on the ' \
                  'attacker; both test beds fill both fields with the same two ' \
                  'strings, so the data cannot settle it (ADR 0036)',
  enemy_critical: 'see actor_critical',
  hp_change_type: 'RPG2003 only — the schema marks it so, and RPG2000 has one ' \
                  'flat/percentage reading rather than a selector',
  sp_change_type: 'see hp_change_type',
}.freeze

# `maker_version` is written only by RPG2003 (RPG2000 omits the chunk), so a run
# that includes one of each can say something the row counts cannot: a field
# **no RPG2000 game sets** is a candidate for being RPG2003-only, which is the
# single most common reason a high-ranked row turns out not to be work.
#
# It is a filter, not a proof, in either direction. An RPG2000 editor still
# writes fields RPG_RT ignores — `levitate` in NOT_OURS above is set by
# Nepheshel despite being 2k3-only — so an unmarked field can still be
# 2k3-only, and a marked one can still be a real RPG2000 feature the 2000 test
# bed simply never used.
#
# `state_chance` used to sit in NOT_OURS on the same "2k3-only" reasoning,
# checked only against Item::vExecute's *medicine* branch (which really does
# ignore it, unconditionally, on both editions). It was never checked against
# Normal::vExecute's *weapon* branch, which reads a weapon's own state_chance
# unconditionally on both editions — and Nepheshel (RPG2000) sets it on
# several real weapons (e.g. item #30, アサシンダガー). Now that
# Game::Actor#weapon_states reads it, this substring search finds the field on
# its own and the entry is gone rather than stale.
def maker_of(db)
  v = db[22] && db[22].maker_version
  v == 2003 ? :rpg2k3 : :rpg2k
rescue StandardError
  :rpg2k
end

# Array-length companions of a packed array. They are set whenever the array is,
# and mean nothing on their own.
def size_field?(name)
  name.to_s.end_with?('_size')
end

# Scalars only: a packed array or a nested table has no single "is it set"
# reading, and the interesting ones (state_set, attribute_set) are already read
# through helpers of their own.
SCALAR = [:int, :bool, :string].freeze

def default_of(f)
  d = f[:default]
  d.respond_to?(:call) ? d.call : d
end

# Is this row's value worth counting as "the author set it"? A default, an empty
# string, a false and a zero all read as "left alone" — which under-reports a
# field whose meaningful value happens to be 0, and that is the safer direction
# for a survey meant to rank things.
def set?(value, dflt)
  return false if value.nil?
  return false if value == dflt
  return false if value == '' || value == false || value == 0
  true
end

dirs = ARGV.empty? ? Dir[File.join(ROOT, 'data/**/RPG_RT.ldb')].sort.map { |f| File.dirname(f) }
                   : ARGV
dirs = dirs.select { |d| File.exist?(File.join(d, 'RPG_RT.ldb')) }
if dirs.empty?
  warn 'no game directory with an RPG_RT.ldb found'
  exit 0
end

runtime = Dir[File.join(ROOT, 'mruby-rpg2k/mrblib/*.rb')]
          .map { |f| File.read(f, encoding: 'UTF-8') }.join("\n")

dbs = dirs.map do |d|
  [File.basename(d), LCF::Database.new(File.open(File.join(d, 'RPG_RT.ldb'), 'rb'))]
end
makers = dbs.map { |label, db| [label, maker_of(db)] }.to_h
mixed = makers.values.uniq.size > 1

rows = []
LCF::Schema::DATABASE[:elements].each do |cid, spec|
  els = spec[:elements]
  next unless els
  els.each_value do |f|
    name = f[:name]
    next unless SCALAR.include?(f[:type])
    next if size_field?(name)
    dflt = default_of(f)
    counts = {}
    dbs.each do |label, db|
      table = db[cid]
      n = 0
      begin
        # An Array1D section (the term table) is one row, not many.
        if table.respond_to?(:each) && !table.respond_to?(name)
          table.each { |_id, r| n += 1 if set?(r.send(name), dflt) }
        elsif table.respond_to?(name)
          n += 1 if set?(table.send(name), dflt)
        end
      rescue StandardError
        next
      end
      counts[label] = n
    end
    total = counts.values.reduce(0) { |a, b| a + b }
    next if total.zero?
    # Set by an RPG2003 game and by no RPG2000 one: suspect until checked.
    only_2k3 = mixed && counts.all? { |label, n| makers[label] == :rpg2k3 || n.zero? }
    rows << { total: total, chunk: spec[:name], field: name, counts: counts,
              named: runtime.include?(name.to_s), only_2k3: only_2k3 }
  end
end

unread = rows.reject { |r| r[:named] }.sort_by { |r| -r[:total] }
read = rows.size - unread.size

puts 'rpg2k database field audit — ' +
     makers.map { |label, m| "#{label} (#{m == :rpg2k3 ? '2k3' : '2k'})" }.join(', ')
puts
puts format('%d scalar field(s) are set by at least one game; the runtime names ' \
            '%d of them and never names %d.', rows.size, read, unread.size)
puts

known, fresh = unread.partition { |r| NOT_OURS.key?(r[:field]) }

puts "-- set by a real game, never named by the runtime ------------------------"
puts format('   %-16s %-28s %6s  %s', 'chunk', 'field', 'rows', 'per game')
fresh.each do |r|
  puts format('   %-16s %-28s %6d  %s%s', r[:chunk], r[:field], r[:total],
              r[:counts].map { |k, v| "#{k}=#{v}" }.join(' '),
              r[:only_2k3] ? '  [2k3 only?]' : '')
end
if mixed
  n = fresh.count { |r| r[:only_2k3] }
  puts
  puts format('   [2k3 only?] marks the %d field(s) an RPG2003 game sets and no ' \
              'RPG2000 one does — check whether RPG_RT reads it on RPG2000 at', n)
  puts '   all before building it. A filter, not a proof, in either direction:'
  puts '   an RPG2000 editor still writes fields RPG_RT ignores, so a field both'
  puts '   makers set can be 2k3-only too (levitate below is).'
end

unless known.empty?
  puts
  puts "-- deliberately not ours -------------------------------------------------"
  known.each do |r|
    puts format('   %s.%s (%d rows)', r[:chunk], r[:field], r[:total])
    puts format('     %s', NOT_OURS[r[:field]])
  end
end

puts
puts 'A row here is a question, not a defect. Check what RPG_RT does with the'
puts 'field (EasyRPG Player is the reference) before implementing anything, and'
puts 'add it to NOT_OURS above if the answer is "nothing, on RPG2000".'
