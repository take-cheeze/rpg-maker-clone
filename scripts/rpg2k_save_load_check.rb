#!/usr/bin/env ruby
# encoding: UTF-8
#
# Integration smoke-test for loading a real Save<N>.lsd into the runtime.
#
# The RPG2000 runtime (mruby-rpg2k) has until now only round-tripped its own
# portable Marshal save. `Game::State.from_lsd` builds a runtime state straight
# from a parsed `LcfSaveData` instead -- i.e. the "Continue" path can resume from
# genuine editor output. That crosses two layers (the LCF save parser and the
# Game:: state model), so this harness loads both sets of mruby/CRuby-common
# sources under CRuby, reconstructs a state from a real `.lsd` and asserts the
# leader position, party, gold, items, switches and variables came through.
#
# The parser's only native dependency (LCF.cp932_to_utf8) is shimmed with Ruby's
# Windows-31J transcoder; RGSS is stubbed since the state model never draws.
#
# Usage:
#   ruby scripts/rpg2k_save_load_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for a directory holding both RPG_RT.ldb and a
# Save*.lsd. Exits non-zero on any failure (or if no save is found to check).

require 'stringio'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  module_function :cp932_to_utf8
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

# RGSS is referenced by mruby-rpg2k at load time but not by the state model.
module RGSS
  module Audio
    class << self
      def bgm_play(*); end
      def se_play(*); end
    end
  end
  def self.warn_stub(*); end
end

ROOT = File.expand_path('..', __dir__)
load File.join(ROOT, 'mruby-lcf', 'mrblib', 'lcf.rb')
load File.join(ROOT, 'mruby-lcf', 'mrblib', 'schema.rb')
load File.join(ROOT, 'mruby-rpg2k', 'mrblib', 'game.rb')

$errors = 0
def eq(expected, actual, msg)
  return if expected == actual
  $errors += 1
  warn "  FAIL #{msg}: expected #{expected.inspect}, got #{actual.inspect}"
end

def check_game(dir)
  save = Dir.glob(File.join(dir, 'Save*.lsd')).sort.first
  unless save
    warn "  skip #{dir}: no Save*.lsd"
    return
  end
  puts "== #{save} =="
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  lsd = LCF::SaveData.new(File.open(save, 'rb'))

  state = Game::State.from_lsd(db, lsd)
  hero = lsd.hero
  inv = lsd.inventory
  sys = lsd[101]

  # Leader position/facing come straight from the hero chunk.
  eq hero.map_id, state.map_id, 'map id'
  eq hero.x, state.x, 'hero x'
  eq hero.y, state.y, 'hero y'
  eq hero.direction, state.direction, 'hero direction'

  # Party roster, gold and items from the inventory chunk. The party leader's
  # database charset must match the saved hero's -- the state really points at
  # the right actor.
  eq((inv.party || []).first, state.party.leader && state.party.leader.id, 'party leader id')
  eq hero.charset_name, (state.party.leader && state.party.leader.charset_name),
     'leader charset matches hero'
  eq inv.gold, state.party.gold, 'gold'
  expected_items = {}
  ids = inv.item_ids || []
  counts = inv.item_counts || []
  ids.each_index { |i| expected_items[ids[i]] = counts[i] }
  eq expected_items, state.party.items, 'items (id => count)'

  # Per-actor current HP/SP come from the SAVE_PARTY_ACTOR table (chunk 108).
  # Each restored roster member must carry the vitals its save entry stored.
  saved = {}
  lsd[108]&.each { |id, sa| saved[id] = sa }
  state.party.actors.each do |a|
    sa = saved[a.id]
    next unless sa
    # Level (which rescales base stats) and exp are restored too, and the
    # rescaled max HP/MP must still bound the restored current HP/MP.
    eq sa.level, a.level, "actor #{a.id} level" if sa.level
    eq sa.exp, a.exp, "actor #{a.id} exp" if sa.exp
    eq sa.hp, a.hp, "actor #{a.id} hp" if sa.hp
    eq sa.mp, a.mp, "actor #{a.id} mp" if sa.mp
    eq true, a.hp <= a.max_hp, "actor #{a.id} hp within max (#{a.hp}/#{a.max_hp})"
    eq true, a.mp <= a.max_mp, "actor #{a.id} mp within max (#{a.mp}/#{a.max_mp})"
    # The saved equipment (chunk 108 field 61) is re-equipped onto the actor.
    eq (sa.equipment || []), a.equipment, "actor #{a.id} equipment" if sa.equipment
    # The saved skills (chunk 108 field 52) are restored as the known-skill set.
    eq (sa.skills || []).sort, a.skills.sort, "actor #{a.id} skills" if sa.skills
  end

  # Switches/variables shift from the save's 0-indexed arrays to 1-indexed ids.
  on = (sys.switches || []).each_index.select { |i| sys.switches[i] }.map { |i| i + 1 }
  eq on, state.switches.to_h.select { |_k, v| v }.keys.sort, 'switch ids that are on'
  nonzero = (sys.variables || []).each_index.reject { |i| sys.variables[i] == 0 }
                                 .map { |i| i + 1 }
  eq nonzero, state.variables.to_h.reject { |_k, v| v == 0 }.keys.sort, 'variable ids set'

  puts "  leader=#{state.party.leader.name.inspect} hp=#{state.party.leader.hp} " \
       "mp=#{state.party.leader.mp} map=#{state.map_id} " \
       "pos=(#{state.x},#{state.y}) gold=#{state.party.gold} " \
       "items=#{state.party.items.size} switches_on=#{on.size} vars_set=#{nonzero.size}"
rescue => e
  $errors += 1
  warn "  FAIL #{dir}: #{e.class}: #{e.message}"
end

def discover(root)
  return [] unless Dir.exist?(root)
  Dir.glob(File.join(root, '**', 'RPG_RT.ldb')).map { |f| File.dirname(f) }
     .select { |d| !Dir.glob(File.join(d, 'Save*.lsd')).empty? }.sort.uniq
end

games = ARGV.dup
games = discover(File.join(ROOT, 'data')) if games.empty?
if games.empty?
  warn 'no game dir with a Save*.lsd found (generate a save first)'
  exit 0
end

games.each { |g| check_game(g) }
if $errors.zero?
  puts 'OK: real save loaded into the runtime cleanly'
else
  warn "#{$errors} error(s)"
end
exit($errors.zero? ? 0 : 1)
