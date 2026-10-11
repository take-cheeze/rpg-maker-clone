#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side checks for the .lsd-authoritative save (docs/adr/0395).
#
# Save<N>.lsd is the only save: Save/Continue writes and reads it, and chunk 200
# of that file carries every Game::State field the engine's old Marshal dump
# carried (docs/adr/0399 removed that dump). This harness checks, under CRuby (the
# same way scripts/rpg2k_logic_check.rb does):
#
#   1. Field by field: the live state, read back through its own fields, equals the
#      same state after a real .lsd write and read, for a set of populated states
#      (party, timers, overrides, switches, variables, pictures in flight and
#      erased, flash, weather, vehicles...).
#   2. The chunk-200 records are each load-bearing: dropping any one of them
#      from the file is caught by check 1's comparison.
#   3. The .lsd writer's chunk-200 marker tells this engine's save apart from an
#      editor save or an old export, and an unknown chunk id survives an
#      LCF::SaveData read/write byte for byte.
#   4. The save-slot policy in RPG2k#save_game / #load_save_state (docs/adr/0399):
#      a save writes Save<N>.lsd alone, on every build; a load reads the .lsd; an old
#      save<N>.mrb is not read; a failed .lsd write fails the save with no fallback.
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
      if !a.key?(k) then out << "#{path}.#{k}: only in the LSD load (#{b[k].inspect[0, 80]})"
      elsif !b.key?(k) then out << "#{path}.#{k}: only in the live state (#{a[k].inspect[0, 80]})"
      else out.concat(deep_diff(a[k], b[k], "#{path}.#{k}"))
      end
    end
  elsif a.is_a?(Array) && b.is_a?(Array) && a.size == b.size
    a.each_index { |i| out.concat(deep_diff(a[i], b[i], "#{path}[#{i}]")) }
  elsif a != b
    out << "#{path}: live=#{a.inspect[0, 90]} lsd=#{b.inspect[0, 90]}"
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

# A populated state touching every field the save carries. Values are realistic
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

# The live state's save-relevant fields, read straight from the live objects. This is
# the reference the .lsd load is compared against, field by field: the same keys and
# values the removed Game::State#to_h held (docs/adr/0399), so a field the .lsd drops
# shows up here as a difference. It reads each object's own fields (ivars and the
# readers it already has), so it does not depend on any engine method that exists
# only for that removed serializer.
def ivars_of(obj, *names)
  names.to_h { |n| [n, obj.instance_variable_get("@#{n}")] }
end

def timer_fields(t)
  { frames: t.frames, running: t.running, visible: t.visible, in_battle: t.in_battle }
end

def vehicle_fields(v)
  { map_id: v.map_id, x: v.x, y: v.y, direction: v.direction,
    charset_name: v.charset_name, charset_index: v.charset_index }
end

def message_config_fields(mc)
  %i[transparent position position_fixed continue_events face_name face_index
     face_right face_flipped].to_h { |n| [n, mc.public_send(n)] }
end

def party_fields(pt)
  hp = {}
  mp = {}
  exp = {}
  meta = {}
  pt.roster.each do |a|
    hp[a.id] = a.hp
    mp[a.id] = a.mp
    exp[a.id] = a.exp
    meta[a.id] = { name: a.name, title: a.title, charset_name: a.charset_name,
                   charset_index: a.charset_index, sprite_changed: a.sprite_changed?,
                   transparent: a.transparent, states: a.states.dup,
                   base_raw: a.base_raw.dup, class_id: a.class_id,
                   class_changed: a.class_changed?, battle_commands: a.battle_commands.dup,
                   row: a.battle_row }
  end
  { actor_ids: pt.actors.map(&:id), items: pt.items, item_usage: pt.item_usage,
    gold: pt.gold, hp: hp, mp: mp, exp: exp, actor_meta: meta }
end

STATE_IVARS = %i[map_id x y direction menu_access save_access current_bgm memorized_bgm
                 pre_vehicle_bgm pre_battle_bgm player_flash player_route player_through
                 player_transparent teleport_access escape_access encounter_rate
                 encounter_total teleport_targets common_event_progress
                 map_event_positions map_event_route_index tile_substitutions steps
                 last_battle_turns save_count battle_count win_count defeat_count
                 escape_count escape_target system_bgm system_sfx screen_transitions
                 system_graphic font_id boarded].freeze

def live_fields(st)
  ivars_of(st, *STATE_IVARS).merge(
    switches: st.switches.to_h, variables: st.variables.to_h,
    party: party_fields(st.party),
    timers: [st.timer(0), st.timer(1)].map { |t| timer_fields(t) },
    timer_frames: st.timer_frames, timer_running: st.timer_running,
    timer_visible: st.timer_visible,
    message_config: message_config_fields(st.message_config),
    weather: st.weather.to_h,
    screen: ivars_of(st.screen, :pan_x, :pan_y, :pan_tx, :pan_ty, :pan_step, :pan_locked),
    pictures: st.instance_variable_get(:@pictures).each_with_object({}) { |(id, p), out| out[id] = p.to_h },
    vehicles: { boat: vehicle_fields(st.vehicle(:boat)), ship: vehicle_fields(st.vehicle(:ship)),
                airship: vehicle_fields(st.vehicle(:airship)) }
  )
end

# The state after a real .lsd write and read back, through the file bytes (the
# same path save_game/load_save_state take).
def via_lsd(db, st)
  bytes = st.to_lsd(st.save_count).to_lcf
  Game::State.from_lsd(db, LCF::SaveData.new(StringIO.new(bytes)))
end


# -- 1. field by field: live state == LSD load -------------------------------

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
  check "LSD save loads back to the live state: #{label}" do
    db = rich_party_db
    st = build.call
    loaded = via_lsd(db, st)
    diffs = deep_diff(live_fields(st), live_fields(loaded))
    ok diffs.empty?, "the live state vs its LSD load differ:\n      " + diffs.join("\n      ")
    # No file-level fixed-point assertion here: writing a reloaded in-flight picture again
    # fails (its fields come back as Floats, which the LCF writer rejects), a pre-existing
    # gap this check does not cover.
  end
end

check 'a fractional picture opacity survives the LSD save exactly, not rounded to ' \
      'the 0..100 transparency chunk 103 carries' do
  db = rich_party_db
  st = rich_state(db)
  st.show_picture(9, { name: 'frac', x: 0, y: 0, zoom: 100, opacity: 199.7 })
  l = via_lsd(db, st)
  eq 199.7, l.pictures[9].to_h[:opacity], 'the fractional opacity round-trips exactly'
  eq 'frac', l.pictures[9].to_h[:name]
end

# -- 2. each chunk-200 record is load-bearing ---------------------------------

# Tag -> the live_fields path(s) the check expects to differ once that record is gone.
EXT_MUTATIONS = {
  Game::State::EXT_TAG_WEATHER => ['weather'],
  Game::State::EXT_TAG_ENCOUNTER_TOTAL => ['encounter_total'],
  Game::State::EXT_TAG_BOARDED => ['boarded'],
  Game::State::EXT_TAG_FLASH => ['player_flash'],
  Game::State::EXT_TAG_COMMON_PROGRESS => ['common_event_progress'],
  Game::State::EXT_TAG_PICTURE_OPACITY => ['pictures'],
}.freeze

EXT_MUTATIONS.each do |tag, paths|
  check "dropping chunk-200 record #{tag} is caught by the field-by-field check" do
    db = rich_party_db
    st = rich_state(db)
    expected = live_fields(st)
    save = st.to_lsd(st.save_count)
    records = Game::State.ext_records(save[:lsd_ext].pack('C*'))
    ok records.any? { |t, _b| t == tag }, "record #{tag} is present in the rich state"
    save[:lsd_ext] = Game::State.ext_payload(records.reject { |t, _b| t == tag }).bytes
    diffs = deep_diff(expected, live_fields(Game::State.from_lsd(db, save)))
    ok !diffs.empty?, "dropping record #{tag} changed nothing: the check would not notice"
    ok diffs.any? { |d| paths.any? { |p| d.start_with?(".#{p}") || d.include?(".#{p}") } },
       "dropping record #{tag} changed #{diffs.inspect}, not #{paths.inspect}"
  end
end

check 'dropping the version record makes the file read as an editor save' do
  db = rich_party_db
  st = rich_state(db)
  save = st.to_lsd(st.save_count)
  ok Game::State.lsd_extended?(save), 'a fresh engine .lsd carries the marker'
  records = Game::State.ext_records(save[:lsd_ext].pack('C*'))
  save[:lsd_ext] = Game::State.ext_payload(records.reject { |t, _b| t == Game::State::EXT_TAG_VERSION }).bytes
  ok !Game::State.lsd_extended?(save), 'without its version record the marker is gone'
end

# -- 3. the marker and unknown chunks ----------------------------------------

check 'a genuine-editor-style .lsd (no chunk 200) loads with the old defaults' do
  db = rich_party_db
  st = rich_state(db)
  save = st.to_lsd(st.save_count)
  save.delete(200)
  ok !Game::State.lsd_extended?(save), 'no chunk 200 means no engine marker'
  old = Game::State.from_lsd(db, save)
  eq 0, old.weather.type, 'weather is not restored from a save that never carried it'
  eq 0, old.encounter_total, 'encounter total defaults to 0'
  eq nil, old.boarded, 'boarded defaults to nil'
  eq 'Renamed Ally', old.party.actor_by_id(2).name, 'the liblcf chunks still restore names'
  eq 30, old.timer(0).seconds, 'the liblcf chunks still restore timers'
  eq 7, old.save_count, 'and save_count (chunk 101 field 131)'
end

check 'an unknown chunk id survives an LCF::SaveData read and write byte for byte' do
  st = rich_state
  bytes = st.to_lsd(st.save_count).to_lcf
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
    diffs = deep_diff(live_fields(st), live_fields(loaded))
    ok diffs.empty?, "the loaded state differs from the saved one:\n      " + diffs.join("\n      ")
  end
end

check 'an old Marshal save (save<N>.mrb, no .lsd) is not read (docs/adr/0399)' do
  with_game_dir do |dir|
    db = rich_party_db
    st = rich_state(db)
    # The bytes of an old Marshal dump: the loader must not read the file at all.
    File.open(File.join(dir, 'save1.mrb'), 'wb') { |f| f.write "\x04\b{\x00".b }
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
