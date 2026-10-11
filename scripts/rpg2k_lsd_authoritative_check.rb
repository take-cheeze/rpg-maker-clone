#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side checks for the .lsd-authoritative save (docs/adr/0395).
#
# New saves use native fields without chunk 200 (ADR 0401). Checks cover
# representable state, documented precision limits, native field mutations,
# legacy extension migration, foreground execution layout and save-slot policy.
#
# Usage: ruby scripts/rpg2k_lsd_authoritative_check.rb   (exits non-zero on failure)

require 'stringio'
require 'tmpdir'
require 'fileutils'

# The native LCF string codec (cp932) and the RGSS audio/warn hooks are not
# touched by the state model; shim them with Ruby's own transcoder, as
# scripts/rpg2k_logic_check.rb does.
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

ROOT = File.expand_path('..', __dir__)
lcf_lib = File.join(ROOT, 'mruby-lcf', 'mrblib')
load File.join(lcf_lib, 'lcf.rb')
load File.join(lcf_lib, 'schema.rb')
load File.join(lcf_lib, 'lcf_file.rb')

lib = File.join(ROOT, 'mruby-rpg2k', 'mrblib')
load File.join(lib, 'game.rb')
load File.join(lib, 'game', 'battle.rb')
load File.join(lib, 'game', 'battle_support.rb')
load File.join(lib, 'game', 'lsd_io.rb')
load File.join(lib, 'interpreter.rb')
load File.join(lib, 'main.rb')

# -- fixtures (the same fake database scripts/rpg2k_logic_check.rb uses) -------

module FixtureFields
  def [](name) = public_send(name)
end

FakePlayerRow = Struct.new(:name, :charset_name, :charset_index,
                           :initial_level, :status, :strong_defence,
                           # The actor's own critical-hit rate: whether it crits
                           # at all, and the 1-in-N denominator it crits at.
                           # Appended after strong_defence so the positional
                           # constructions above keep working; a row that names
                           # neither never crits, which is what a bare fixture
                           # wants.
                           :has_critical_rate, :critical_rate,
                           # 二刀流 -- turns the shield slot into a second
                           # weapon slot (Actor#double_hand?). Appended last for
                           # the same reason: every existing positional
                           # construction keeps working with it defaulting nil.
                           :double_hand,
                           # 装備固定 -- Actor#equipment_fixed?. Same reasoning.
                           :equipment_fixed,
                           # The actor's default FaceSet portrait (Enter Hero
                           # Name's face box). Same reasoning: appended last.
                           :faceset_name, :faceset_index,
                           # 素手戦闘アニメID -- the battle animation a basic
                           # Attack plays with no weapon equipped
                           # (Actor#attack_animation_id). Same reasoning:
                           # appended last, defaults nil (no animation).
                           :unarmed_animation,
                           # 強制AI -- Actor#force_ai?. Same reasoning: appended
                           # last, defaults nil (never AI-controlled).
                           :force_ai,
                           # RPG2003's manual battle-sprite position (chunk 11
                           # fields 59/60, Actor#battle_x/#battle_y) and the
                           # actor's own database-default battle animation id
                           # (field 62, into db.battleranimations --
                           # Actor#battler_animation_id's "else" branch).
                           # Same reasoning: appended last, nil reads as 0 via
                           # the reader methods, matching the schema default.
                           :battle_x, :battle_y, :battler_animation)

FakeActorSystem = Struct.new(:party, :equipment_setting)

class FakeActorDB

  include FixtureFields
  attr_reader :player, :system, :item, :skill, :job, :situation, :property, :battlecommands,
              :enemy_group, :battleranimations, :term
  # Writable (unlike the others above): nil by default, matching a database
  # with no chipset/terrain chunk at all -- set directly on an instance by
  # the handful of checks that need Game::ChipSet/#terrain resolution (e.g.
  # SAVE_SYSTEM field 125's own database-backed lookup).
  attr_accessor :chipset, :terrain
  def common_event
    { 1 => { event: [LCF::EventCommand.new(11410, 0, '', [1]),
                     LCF::EventCommand.new(11410, 0, '', [1]),
                     LCF::EventCommand.new(0, 0, '', [])] } }
  end
  # `enemy_group` defaults to "every id exists" (Hash.new(true)) since most
  # checks using this fixture have nothing to do with troop validity; pass an
  # explicit hash (e.g. {}) to exercise the missing-troop-id diagnostic path.
  # `battleranimations` mirrors `db.battleranimations` (chunk 32, id ->
  # FakeBattlerAnimation) -- nil (the default, same as a genuine RPG2000
  # database that never carries the chunk) for every check that doesn't need
  # Actor#battler_animation_id's resolved id to name a real entry.
  def initialize(players, party_ids, items = {}, skills = {}, jobs = {}, situation = nil,
                 property = nil, rpg2003: false, battlecommands: nil,
                 enemy_group: Hash.new(true), battleranimations: nil,
                 equipment_setting: nil, term: nil)
    @player = players
    @system = FakeActorSystem.new(party_ids, equipment_setting)
    @item = items
    @skill = skills
    @job = jobs
    @situation = situation
    @property = property
    @rpg2003 = rpg2003
    @battlecommands = battlecommands
    @enemy_group = enemy_group
    @battleranimations = battleranimations
    @term = term
  end

  # Mirrors LCF::Schema::Database#rpg2003? (Classes-chunk presence) for tests
  # that need to distinguish the two editions' own numeric ranges/caps.
  def rpg2003?; @rpg2003; end
end

# -- tiny test framework ------------------------------------------------------

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
  warn "    #{e.backtrace.first}"
end

def eq(expected, actual, msg = nil)
  return if expected == actual
  raise "expected #{expected.inspect}, got #{actual.inspect}#{msg ? " (#{msg})" : ''}"
end

def ok(cond, msg = 'expected truthy')
  raise msg unless cond
end

def capture_stderr
  old = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old
end

# -- helpers ------------------------------------------------------------------

# Every difference between two plain-data trees (Hash/Array/scalar), as
# "path: a vs b" strings. [] means identical.
def deep_diff(a, b, path = '')
  out = []
  if a.is_a?(Hash) && b.is_a?(Hash)
    (a.keys | b.keys).each do |k|
      if !a.key?(k) then out << "#{path}.#{k}: only in LSD (#{b[k].inspect[0, 80]})"
      elsif !b.key?(k) then out << "#{path}.#{k}: only in Marshal (#{a[k].inspect[0, 80]})"
      else out.concat(deep_diff(a[k], b[k], "#{path}.#{k}"))
      end
    end
  elsif a.is_a?(Array) && b.is_a?(Array) && a.size == b.size
    a.each_index { |i| out.concat(deep_diff(a[i], b[i], "#{path}[#{i}]")) }
  elsif a.is_a?(Numeric) && b.is_a?(Numeric) && (a - b).abs < 1e-9
    # Wire double conversions may introduce one rounding bit.
  elsif a != b
    out << "#{path}: expected=#{a.inspect[0, 90]} lsd=#{b.inspect[0, 90]}"
  end
  out
end

def rich_party_db
  players = {
    1 => FakePlayerRow.new('Hero', 'Hero.png', 0, 5, max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', 'Ally.png', 1, 3, max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  FakeActorDB.new(players, [1])
end

# A populated state touching every field Marshal carries. Values are realistic
# shapes (see the producers in interpreter.rb / scene/map.rb).
def rich_state(db = rich_party_db)
  party = Game::Party.new(db)
  party.add_actor(2)
  st = Game::State.new(party, 3, 4, 5)
  st.direction = 6
  st.party.leader.name = 'Renamed Hero'
  st.party.leader.title = 'Lead'
  st.party.actor_by_id(2).name = 'Renamed Ally'
  st.party.actor_by_id(2).title = 'Ally Title'
  st.switches[5] = true
  st.switches[17] = true
  st.variables[3] = 42
  st.variables[9] = -7
  st.timer(0).set(30)
  st.timer(0).start(true, true)
  st.timer(1).set(90)
  st.timer(1).start(false, false)
  st.save_count = 7
  st.battle_count = 4
  st.win_count = 2
  st.defeat_count = 1
  st.escape_count = 1
  st.steps = 123
  st.last_battle_turns = 5
  st.encounter_rate = 12
  st.encounter_total = 3
  st.menu_access = false
  st.save_access = false
  st.teleport_access = false
  st.escape_access = true
  st.current_bgm = { name: 'Town', fadein: 0, volume: 80, tempo: 100, balance: 50 }
  st.memorized_bgm = { name: 'Field', fadein: 0, volume: 70, tempo: 100, balance: 50 }
  st.pre_battle_bgm = { name: 'Old', fadein: 0, volume: 60, tempo: 100, balance: 50 }
  st.system_bgm = { 1 => { name: 'Fight', fadein: 0, volume: 90, tempo: 100, balance: 50 } }
  st.system_sfx = { 2 => { name: 'Cur', volume: 50, tempo: 100, balance: 50 } }
  st.player_flash = { red: 8, green: 0, blue: 16, power: 40.0, frames: 9, total: 12 }
  st.player_transparent = true
  st.player_through = true
  st.weather.set(2, 2)
  st.screen.tint_to(10, 20, 30, 40, 50)
  st.show_picture(3, { name: 'pic', x: 10, y: 20, zoom: 100, opacity: 200.25,
                       fixed_to_map: true, use_transparent_color: true })
  st.show_picture(4, { name: 'erased', x: 1, y: 2, zoom: 100, opacity: 255 })
  st.erase_picture(4)
  st.teleport_targets = { 2 => { x: 3, y: 4, switch_id: 9 } }
  st.escape_target = { map_id: 5, x: 6, y: 7, switch_id: 11 }
  st.common_event_progress = { 1 => 2 }
  st.map_event_positions = { 3 => [4, 5, 6] }
  st.map_event_route_index = { 3 => 1 }
  st.tile_substitutions = [{ 1 => 2 }, { 3 => 4 }]
  st.font_id = 2
  st.system_graphic = 'System.png'
  st.boarded = :airship
  st.vehicle(:boat).map_id = 1
  st.vehicle(:boat).x = 2
  st.vehicle(:boat).y = 3
  st.vehicle(:boat).direction = 4
  st.vehicle(:boat).charset_name = 'Boat'
  st.vehicle(:boat).charset_index = 1
  st.vehicle(:airship).map_id = 6
  st.vehicle(:airship).x = 7
  st.vehicle(:airship).y = 8
  st.pre_vehicle_bgm = { name: 'Before', fadein: 0, volume: 55, tempo: 100, balance: 50 }
  mc = st.message_config
  mc.transparent = true
  mc.position = 1
  mc.position_fixed = true
  mc.continue_events = true
  mc.face_name = 'Face'
  mc.face_index = 2
  mc.face_right = true
  mc.face_flipped = true
  st.seed_screen_transitions(db)
  st
end

# Marshal round trip of the state's own save hash.
def via_marshal(db, st)
  Game::State.load(db, Marshal.load(Marshal.dump(st.to_h)))
end

# The state after a real .lsd write and read back, through the file bytes (the
# same path save_game/load_save_state take).
def via_lsd(db, st)
  bytes = st.to_lsd(st.save_count, nil, 1, db).to_lcf
  Game::State.from_lsd(db, LCF::SaveData.new(StringIO.new(bytes)))
end

def lsd_bytes(st)
  st.to_lsd(st.save_count, nil, 1, rich_party_db).to_lcf
end

# Only the native format's documented information losses are canonicalized.
def native_snapshot(st)
  h = Marshal.load(Marshal.dump(st.to_h))
  if (flash = h[:player_flash]) && flash[:frames] > 0
    total = flash[:total] && flash[:total] > 0 ? flash[:total] : flash[:frames]
    flash[:power] = flash[:power].to_f * flash[:frames] / total
    flash[:total] = flash[:frames]
  end
  h[:pictures].each do |id, pic|
    pic[:name] = '' unless st.pictures[id].shown?
    if pic[:topacity]
      trans = (100.0 - pic[:topacity] * 100.0 / 255.0).round
      pic[:topacity] = Game.trans_to_opacity(trans)
    end
  end
  h
end

# -- 1. field by field: native representable state --------------------------

# A new-game state, seeded the way a real new game is (screen transitions come
# from the database; a fresh State has none until seeded).
def seeded_state(db, map_id, x, y)
  st = Game::State.new(Game::Party.new(db), map_id, x, y)
  st.seed_screen_transitions(db)
  st
end

SCENARIOS = {
  'rich state (every field)' => -> { rich_state },
  'default new party' => lambda do
    db = rich_party_db
    st = Game::State.new(Game::Party.new(db), 1, 0, 0)
    st.seed_screen_transitions(db)
    st
  end,
  'live moving picture and flash' => lambda do
    st = seeded_state(rich_party_db, 2, 1, 1)
    st.show_picture(7, { name: 'moving', x: 5, y: 6, zoom: 100, opacity: 255 })
    st.move_picture(7, 50, 60, 150, 128, 10, 20, 30, 40, 24)
    st.player_flash = { red: 31, green: 0, blue: 0, power: 17.5, frames: 3, total: 9 }
    st
  end,
  'boat boarded' => lambda do
    st = seeded_state(rich_party_db, 2, 1, 1)
    st.boarded = :boat
    st
  end,
  'ship boarded, weather rain' => lambda do
    st = seeded_state(rich_party_db, 2, 1, 1)
    st.boarded = :ship
    st.weather.set(1, 1)
    st
  end,
}

SCENARIOS.each do |label, build|
  check "native LSD preserves representable state: #{label}" do
    db = rich_party_db
    st = build.call
    expected = native_snapshot(st)
    l = via_lsd(db, st).to_h
    diffs = deep_diff(expected, l)
    ok diffs.empty?, "the live state vs its LSD load differ:\n      " + diffs.join("\n      ")
  end
end

check 'a fractional picture opacity survives the LSD save exactly, not rounded to ' \
      'the 0..100 transparency chunk 103 carries' do
  db = rich_party_db
  st = rich_state(db)
  st.show_picture(9, { name: 'frac', x: 0, y: 0, zoom: 100, opacity: 199.7 })
  l = via_lsd(db, st)
  ok((199.7 - l.pictures[9].to_h[:opacity]).abs < 1e-9, 'fractional current opacity is preserved')
  eq 'frac', l.pictures[9].to_h[:name]
end

# -- 2. native field mutations must be observed -------------------------------

NATIVE_MUTATIONS = {
  'weather' => [102, [48, 49], '.weather'],
  'encounter accumulation' => [104, [124], '.encounter_total'],
  'boarded vehicle' => [104, [102, 103], '.boarded'],
  'flash level' => [104, [84], '.player_flash'],
  'common-event progress' => [114, nil, '.common_event_progress'],
  'fractional current opacity' => [103, nil, '.pictures'],
  'pan target' => [104, [114], '.screen'],
}.freeze

NATIVE_MUTATIONS.each do |label, (chunk, fields, path)|
  check "dropping native #{label} changes the restored state" do
    db = rich_party_db
    st = rich_state(db)
    st.screen.pan(1, 2, 3)
    st.screen.update
    expected = via_lsd(db, st).to_h
    save = st.to_lsd(st.save_count, nil, 1, db)
    if fields
      row = save[chunk]
      fields.each { |id| row.delete(id) }
      save[chunk] = row
    else
      save.delete(chunk)
    end
    diffs = deep_diff(expected, Game::State.from_lsd(db, save).to_h)
    ok diffs.any? { |d| d.start_with?(path) }, "mutation not detected: #{diffs.inspect}"
  end
end

check 'new saves contain only native top-level chunks, never the extension' do
  db = rich_party_db
  save = rich_state(db).to_lsd(nil, nil, 1, db)
  ok !save.key?(200), 'chunk 200 is absent'
  ok !Game::State.lsd_extended?(save), 'the old marker is absent'
  row = save.instance_variable_get(:@root)
  ids = row.instance_variable_get(:@data).each_index.select { |i| row.key?(i) }
  ok ids.all? { |i| (100..114).include?(i) }, "non-native chunk ids: #{ids.inspect}"
end

# Captured from the pre-migration writer, including every legacy record kind.
LEGACY_EXTENSION = [0, 1, 1, 1, 2, 2, 2, 2, 1, 3, 3, 1, 3, 4, 13, 8, 0, 16, 9, 12,
  0, 0, 0, 0, 0, 0, 68, 64, 5, 2, 1, 2, 6, 31, 3, 3, 112, 105, 99, 0, 0, 0, 0,
  0, 8, 105, 64, 0, 4, 6, 101, 114, 97, 115, 101, 100, 0, 0, 0, 0, 0, 224, 111,
  64, 0, 7, 41, 0, 0, 0, 0, 0, 0, 240, 63, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 64, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 240, 63, 0].freeze

check 'a legacy extension loads exactly, then re-saves using native chunks' do
  db = rich_party_db
  st = rich_state(db)
  st.screen.pan(1, 2, 3)
  st.screen.update
  save = st.to_lsd(nil, nil, 1, db)
  save[:lsd_ext] = LEGACY_EXTENSION
  loaded = Game::State.from_lsd(db, save)
  diffs = deep_diff(st.to_h, loaded.to_h)
  ok diffs.empty?, "legacy state changed: #{diffs.inspect}"
  ok !loaded.to_lsd(nil, nil, 1, db).key?(200), 're-saving migrates the old extension'
end

check 'an unrelated native/tooling chunk 200 is ignored by the runtime' do
  db = rich_party_db
  st = rich_state(db)
  save = st.to_lsd(nil, nil, 1, db)
  save[:lsd_ext] = [1, 1, 0, 0, 0]
  ok !Game::State.lsd_extended?(save), 'unmarked bytes are not our legacy extension'
  diffs = deep_diff(native_snapshot(st), Game::State.from_lsd(db, save).to_h)
  ok diffs.empty?, "unrelated chunk changed state: #{diffs.inspect}"
end

check 'an unsupported legacy extension version fails explicitly' do
  db = rich_party_db
  save = rich_state(db).to_lsd(nil, nil, 1, db)
  save[:lsd_ext] = [0, 1, 2]
  begin
    Game::State.from_lsd(db, save)
    raise 'unsupported version was accepted'
  rescue RuntimeError => e
    ok e.message.include?('unsupported legacy LSD extension version 2'), e.message
  end
end

check 'legacy wrapped foreground frames still load' do
  db = rich_party_db
  st = rich_state(db)
  frame = { commands: [LCF::EventCommand.new(11410, 0, '', [1])], current_command: 1, event_id: 5 }
  st.foreground_event_exec = { frames: [frame] }
  save = st.to_lsd(nil, nil, 1, db)
  wrapper = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_LEGACY_FOREGROUND_EVENT })
  wrapper[1] = save[113]
  save[113] = wrapper
  save[:lsd_ext] = [0, 1, 1]
  loaded = Game::State.from_lsd(db, save)
  eq 5, loaded.foreground_event_exec[:event_id]
  eq 1, loaded.foreground_event_exec[:frames][0][:current_command]
end

check 'cursor-only common progress requires a database command list' do
  db = rich_party_db
  begin
    rich_state(db).to_lsd
    raise 'cursor without commands was silently discarded'
  rescue RuntimeError => e
    ok e.message.include?('needs its database command list'), e.message
  end
end

check 'an unknown chunk id survives an LCF::SaveData read and write byte for byte' do
  st = rich_state
  bytes = st.to_lsd(st.save_count, nil, 1, rich_party_db).to_lcf
  extra = LCF.write_ber(201) + LCF.write_ber(3) + 'xyz'
  with_unknown = bytes + extra
  save = LCF::SaveData.new(StringIO.new(with_unknown))
  eq with_unknown, save.to_lcf, 'read then write reproduces the file, unknown chunk included'
  # ...and the real chunks still load next to it.
  round = Game::State.from_lsd(rich_party_db, LCF::SaveData.new(StringIO.new(with_unknown)))
  eq 'Renamed Hero', round.party.leader.name
end

# -- 4. the save-slot policy (RPG2k#save_game / #load_save_state, docs/adr/0399) ---

# The real main.rb's RPG2k, bound to a scratch game directory and a fake database.
def policy_app(db)
  app = RPG2k.allocate
  app.instance_variable_set(:@db, db)
  app.instance_variable_set(:@map_tree, nil)
  app
end

def with_game_dir
  Dir.mktmpdir('lsd-authoritative') do |dir|
    Object.send(:remove_const, :GAME_DIR) if Object.const_defined?(:GAME_DIR)
    Object.const_set(:GAME_DIR, dir)
    yield dir
  end
end

check 'a save writes the .lsd alone, and a load reads it back' do
  with_game_dir do |dir|
    db = rich_party_db
    app = policy_app(db)
    st = rich_state(db)
    ok app.save_game(st, 1), 'save_game reports success'
    ok File.exist?(File.join(dir, 'Save01.lsd')), 'the .lsd is written'
    ok !File.exist?(File.join(dir, 'save1.mrb')), 'no Marshal dump is written'
    loaded = app.load_save_state(1)
    ok loaded, 'the slot loads'
    diffs = deep_diff(native_snapshot(st), loaded.to_h)
    ok diffs.empty?, "the loaded state differs from the saved one:\n      " + diffs.join("\n      ")
  end
end

check 'an old Marshal save (save<N>.mrb, no .lsd) is not read (docs/adr/0399)' do
  with_game_dir do |dir|
    db = rich_party_db
    st = rich_state(db)
    File.open(File.join(dir, 'save1.mrb'), 'wb') { |f| f.write Marshal.dump(st.to_h) }
    ok !policy_app(db).any_save_exists?, 'a slot holding only a .mrb counts as empty'
    ok policy_app(db).load_save_state(1).nil?, 'and loads as nothing'
  end
end

check 'a failed .lsd write fails the save and writes no Marshal fallback' do
  with_game_dir do |dir|
    db = rich_party_db
    st = rich_state(db)
    st.define_singleton_method(:to_lsd) { |*_a| raise 'simulated export failure' }
    app = policy_app(db)
    out = capture_stderr { eq false, app.save_game(st, 1), 'the save reports failure' }
    ok out.include?('simulated export failure'), 'the failure is logged'
    ok !File.exist?(File.join(dir, 'save1.mrb')), 'no Marshal fallback'
    ok !File.exist?(File.join(dir, 'Save01.lsd')), 'no .lsd is left behind'
  end
end

check 'an unreadable .lsd loads as an empty slot, and says so' do
  with_game_dir do |dir|
    db = rich_party_db
    File.open(File.join(dir, 'Save01.lsd'), 'wb') { |f| f.write 'not an lcf file' }
    loaded = :unset
    out = capture_stderr { loaded = policy_app(db).load_save_state(1) }
    ok loaded.nil?, 'the slot resolves to nothing rather than raising'
    ok out.include?('unreadable'), 'the failure is logged'
  end
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k lsd authoritative check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k lsd authoritative check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
