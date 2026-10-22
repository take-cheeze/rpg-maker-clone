#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side checks for native pan and picture saves (hero fields and chunk 103 of
# Save<N>.lsd):
#
#   1. The Pan Screen lock is written and restored.
#   2. A Pan Screen scroll still in flight keeps its target and step, so it
#      resumes instead of snapping to the offset.
#   3. A reloaded in-flight moving picture with a Float target opacity saves
#      without raising (LCF's integer BER writer rejects a Float).
#
# Runs under CRuby, with the same shims as scripts/rpg2k/lsd_authoritative_check.rb.
#
# Usage: ruby scripts/rpg2k/lsd_pan_picture_check.rb   (exits non-zero on failure)

require 'stringio'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  def utf8_to_cp932(s)
    s.dup.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

module RGSS
  module Audio
    class << self
      def bgm_play(*); end
      def bgm_volume(*); end
      def bgm_pan(*); end
      def se_play(*); end
    end
  end
  def self.warn_stub(*); end
end

ROOT = File.expand_path('../..', __dir__)
lcf_lib = File.join(ROOT, 'mruby-lcf', 'mrblib')
load File.join(lcf_lib, 'lcf.rb')
load File.join(lcf_lib, 'schema.rb')
load File.join(lcf_lib, 'lcf_file.rb')
load File.join(lcf_lib, 'save_typed.rb')
load File.join(lcf_lib, 'save_typed_accessors.rb')

lib = File.join(ROOT, 'mruby-rpg2k', 'mrblib')
load File.join(lib, 'game.rb')
load File.join(lib, 'game', 'battle.rb')
load File.join(lib, 'game', 'battle_support.rb')
load File.join(lib, 'game', 'legacy_lsd.rb')
load File.join(lib, 'game', 'lsd_io.rb')
load File.join(lib, 'interpreter.rb')
load File.join(lib, 'main.rb')

# -- minimal database: an empty RPG2000 party, enough for Game::State ----------

FakeSystem = Struct.new(:party, :equipment_setting)

class FakePanDB
  def initialize
    @system = FakeSystem.new([], nil)
  end
  def [](name) = public_send(name)
  def system = @system
  def player = []
  def rpg2003? = false
end

# -- tiny test framework ------------------------------------------------------

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
  puts "ok   #{name}"
rescue StandardError => e
  $failures += 1
  puts "FAIL #{name}: #{e.class}: #{e.message}"
end

def ok(cond, msg = 'expected truthy')
  raise msg unless cond
end

def eq(expected, actual, msg = nil)
  raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
end

def lsd_round_trip(db, st)
  bytes = st.to_lsd(st.save_count).to_lcf
  Game::State.from_lsd(db, LCF::SaveData.new(StringIO.new(bytes)))
end

def fresh_state(db)
  Game::State.new(Game::Party.new(db), 1, 0, 0)
end

db = FakePanDB.new

check 'pan lock survives a .lsd round trip at rest' do
  st = fresh_state(db)
  st.screen.pan_lock
  back = lsd_round_trip(db, st)
  ok back.screen.pan_locked?, 'the lock was dropped on load'
  eq [0, 0], back.screen.pan_offset
end

check 'a plain save at rest loads unlocked and centred' do
  st = fresh_state(db)
  back = lsd_round_trip(db, st)
  ok !back.screen.pan_locked?, 'a plain save loaded as locked'
end

check 'a pan still in flight keeps its target and step across a round trip' do
  st = fresh_state(db)
  st.screen.pan(0, 3, 4)
  st.screen.update
  before = st.screen.pan_save_data
  ok st.screen.panning?, 'the pan should still be in flight'
  back = lsd_round_trip(db, st)
  eq before, back.screen.pan_save_data
  ok back.screen.panning?, 'the in-flight pan came back at rest'
end

check 'a locked, off-centre pan keeps its offset and lock' do
  st = fresh_state(db)
  st.screen.pan(1, 2, 4)
  50.times { st.screen.update }
  st.screen.pan_lock
  before = st.screen.pan_save_data
  back = lsd_round_trip(db, st)
  eq before, back.screen.pan_save_data
  ok back.screen.pan_locked?, 'the lock was dropped on load'
end

check 'an in-flight picture with a Float target opacity saves without raising' do
  st = fresh_state(db)
  st.show_picture(7, { name: 'moving', x: 5, y: 6, zoom: 100, opacity: 255 })
  st.move_picture(7, 50, 60, 150, 128.5, 10, 20, 30, 40, 24)
  back = lsd_round_trip(db, st)
  again = lsd_round_trip(db, back)
  ok back.pictures[7].moving?, 'the picture stopped moving on load'
  eq back.pictures[7].finish_opacity.to_i, again.pictures[7].finish_opacity.to_i
end

check 'a reloaded moving picture re-saves after a second round trip' do
  st = fresh_state(db)
  st.show_picture(9, { name: 'frac', x: 0, y: 0, zoom: 100, opacity: 199.7 })
  st.move_picture(9, 20, 30, 100, 64.25, 100, 100, 100, 100, 10)
  first = lsd_round_trip(db, st)
  second = lsd_round_trip(db, first)
  ok second.pictures[9].moving?, 'the picture stopped moving after two loads'
end

puts "#{$checks - $failures}/#{$checks} checks passed"
exit($failures.zero? ? 0 : 1)
