#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side robustness checks for reading a Save<N>.lsd that this engine did not
# write.
#
# No genuine RPG_RT / EasyRPG save is reachable from the repo (none is committed,
# and scripts/download/* fetch games, not saves), so the fixtures here are built
# from the LCF format itself: a populated save written through the schema, then
# reshaped byte by byte into the ways a real file differs from what this writer
# emits. Three guarantees are asserted:
#
#   1. a valid-but-unusual save LOADS (fields the schema does not know, a
#      trailing terminator or trailing garbage, padded BER numbers, every schema
#      field present at once, a full-size table, a present-but-empty field);
#   2. a save that genuinely does not match its schema (a field of the wrong size
#      or type, a chunk that runs past the end of the file, an absurd chunk id, a
#      file with no header, an empty or header-only file) is an EMPTY SLOT with
#      the reason logged: RPG2k#load_save_state returns nil and prints
#      "save slot N unreadable: <reason>";
#   3. NOTHING CRASHES: every truncation of a valid save and a seeded set of
#      byte corruptions only ever yield a loaded state or a logged empty slot.
#
# Usage: ruby scripts/rpg2k/lsd_adversarial_check.rb   (exits non-zero on failure)

require 'stringio'
require 'tmpdir'

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
%w[lcf.rb schema.rb lcf_file.rb save_typed.rb save_typed_accessors.rb].each { |f| load File.join(lcf_lib, f) }
lib = File.join(ROOT, 'mruby-rpg2k', 'mrblib')
%w[game.rb game/battle.rb game/battle_support.rb game/legacy_lsd.rb game/lsd_io.rb
   interpreter.rb main.rb].each { |f| load File.join(lib, f) }

# -- a fake database (the shape scripts/rpg2k/lsd_authoritative_check.rb uses) ---------

module FixtureFields
  def [](name) = public_send(name)
end

FakePlayerRow = Struct.new(:name, :charset_name, :charset_index, :initial_level, :status,
                           :strong_defence, :has_critical_rate, :critical_rate, :double_hand,
                           :equipment_fixed, :faceset_name, :faceset_index, :unarmed_animation,
                           :force_ai, :battle_x, :battle_y, :battler_animation)
FakeActorSystem = Struct.new(:party, :equipment_setting)

class FakeActorDB
  include FixtureFields
  attr_reader :player, :system, :item, :skill, :job, :situation, :property, :battlecommands,
              :enemy_group, :battleranimations, :term
  attr_accessor :chipset, :terrain
  def common_event; {}; end

  def initialize(players, party_ids, rpg2003: false)
    @player = players
    @system = FakeActorSystem.new(party_ids, nil)
    @item = {}
    @skill = {}
    @job = {}
    @enemy_group = Hash.new(true)
    @rpg2003 = rpg2003
  end

  def rpg2003?; @rpg2003; end
end

def party_db(rpg2003: false)
  players = {
    1 => FakePlayerRow.new('Hero', 'Hero.png', 0, 5, max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', 'Ally.png', 1, 3, max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  FakeActorDB.new(players, [1], rpg2003: rpg2003)
end

# -- tiny test framework -----------------------------------------------------------------

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

# -- save bytes ----------------------------------------------------------------------------

def base_state(db)
  party = Game::Party.new(db)
  party.add_actor(2)
  st = Game::State.new(party, 3, 4, 5)
  st.switches[5] = true
  st.variables[3] = 42
  st.save_count = 7
  st.seed_screen_transitions(db)
  st
end

BASE_DB = party_db
BASE_BYTES = base_state(BASE_DB).to_lsd(7, nil, 1, BASE_DB).to_lcf.b.freeze

def ber(n) = LCF.write_ber(n)

# One chunk as it sits in a file.
def chunk(id, payload) = ber(id) + ber(payload.bytesize) + payload.b

HEADER = (ber('LcfSaveData'.bytesize) + 'LcfSaveData'.b).freeze

# The [id, payload] chunk list of a record stream (a top-level file when +skip_header+).
def chunks_of(bytes, skip_header: true)
  io = StringIO.new(bytes)
  io.read(LCF.read_ber(io)) if skip_header
  out = []
  until io.eof?
    id = LCF.read_ber(io)
    break if id == 0
    out << [id, io.read(LCF.read_ber(io))]
  end
  out
end

def file_of(pairs) = HEADER + pairs.map { |id, p| chunk(id, p) }.join.b

# A nested record's bytes: its chunks and the id-0 terminator.
def record(pairs) = pairs.map { |i, p| chunk(i, p) }.join.b + ber(0)

# +bytes+ with top-level chunk +id+ replaced (or added when absent) by +payload+.
def with_chunk(bytes, id, payload)
  pairs = chunks_of(bytes).reject { |i, _| i == id }
  pairs << [id, payload]
  file_of(pairs.sort_by(&:first))
end

# Replace field +fid+ of top-level record +cid+ with the raw +payload+.
def with_field(bytes, cid, fid, payload)
  inner = chunks_of(chunks_of(bytes).to_h[cid] || ber(0), skip_header: false).reject { |i, _| i == fid }
  inner << [fid, payload]
  with_chunk(bytes, cid, record(inner.sort_by(&:first)))
end

# -- loading a save the way the game does ----------------------------------------------------

# RPG2k#load_save_state over +bytes+ on disk: [state or nil, what it logged]. A raise
# out of load_save_state breaks the contract, so it is deliberately not rescued here.
def load_slot(bytes, db: BASE_DB)
  Dir.mktmpdir('lsd-adversarial') do |dir|
    Object.send(:remove_const, :GAME_DIR) if Object.const_defined?(:GAME_DIR)
    Object.const_set(:GAME_DIR, dir)
    File.binwrite(File.join(dir, 'Save01.lsd'), bytes)
    app = RPG2k.allocate
    app.instance_variable_set(:@db, db)
    app.instance_variable_set(:@map_tree, nil)
    state = nil
    err = capture_stderr { state = app.load_save_state(1) }
    [state, err]
  end
end

def loads(bytes, what, db: BASE_DB)
  state, err = load_slot(bytes, db: db)
  ok state, "#{what}: expected the save to load, got an empty slot (#{err.strip})"
  state
end

def empty_slot(bytes, what, reason, db: BASE_DB)
  state, err = load_slot(bytes, db: db)
  ok state.nil?, "#{what}: expected an empty slot, but it loaded"
  ok err.include?('save slot 1 unreadable: '), "#{what}: the reason is logged (got #{err.inspect})"
  ok err.include?(reason), "#{what}: the log names #{reason.inspect} (got #{err.strip.inspect})"
end

# A value for every schema field kind, to build a save with every field present.
def sample_value(field, depth = 0)
  case field[:type]
  when :int then 12_345 - depth
  when :uint8 then 200
  when :bool then true
  when :double then 41_000.5
  when :string then 'Sample'
  when :int8_array then [1, 2, 3, 250]
  when :bool_array then [true, false, true]
  when :int16_array then [1, -2, 300]
  when :int32_array then [1, -2, 70_000]
  when :event
    [LCF::EventCommand.new(10110, 0, 'hi', [0, 1, 2]), LCF::EventCommand.new(0, 0, '', [])]
  when :move_commands
    [{ command_id: 1 }, { command_id: 32, parameter_a: 3 },
     { command_id: 34, parameter_string: 'x', parameter_a: 1 }]
  when :Array1D
    rec = LCF::Array1D.new('', field)
    LCF.elements_of(field).each { |id, f| rec[id] = sample_value(f, depth + 1) }
    rec
  when :Array2D
    tbl = LCF::Array2D.new('', field)
    [1, 2, 50].each do |row|
      rec = LCF::Array1D.new('', field)
      LCF.elements_of(field).each { |id, f| rec[id] = sample_value(f, depth + 1) }
      tbl[row] = rec
    end
    tbl
  else raise "no sample for #{field[:type]}"
  end
end

def fully_populated_save
  save = LCF::SaveData.new
  LCF::Schema::SAVE_DATA[:elements].each { |id, f| save[id] = sample_value(f) }
  save
end

# -- 0. the baseline -------------------------------------------------------------------------

check 'baseline: the engine\'s own save loads' do
  st = loads(BASE_BYTES, 'baseline')
  eq 3, st.map_id
  eq 4, st.x
  ok st.switches[5], 'switch 5'
  eq 42, st.variables[3]
end

# -- 1. valid but unusual saves load ---------------------------------------------------------

check 'a chunk id the schema does not know loads and survives a rewrite' do
  bytes = with_chunk(BASE_BYTES, 150, "\x01\x02\x03".b)
  st = loads(bytes, 'unknown top-level chunk 150')
  eq 3, st.map_id
  eq bytes, LCF::SaveData.new(StringIO.new(bytes)).to_lcf, 'unknown chunk kept byte for byte'
end

check 'a field the schema does not know inside a known record loads' do
  [[100, 9999], [104, 9998], [101, 777], [109, 500]].each do |cid, fid|
    bytes = with_field(BASE_BYTES, cid, fid, "\xff\xfe".b)
    loads(bytes, "unknown field #{fid} in chunk #{cid}")
    eq bytes, LCF::SaveData.new(StringIO.new(bytes)).to_lcf, "field #{fid} kept"
  end
end

check 'an unrelated chunk 200 (tooling or a foreign writer) is ignored' do
  ["\x00" * 5, 'EasyRPG', ''].each do |blob|
    loads(with_chunk(BASE_BYTES, 200, blob.b), "chunk 200 #{blob.inspect}")
  end
end

check 'trailing data after the chunk list does not stop the save loading' do
  loads(BASE_BYTES + ber(0), 'one trailing terminator')
  loads(BASE_BYTES + ber(0) + "\xde\xad\xbe\xef".b, 'garbage after the terminator')
  loads(BASE_BYTES + ("\x00".b * 64), 'a zero-padded tail')
end

check 'a BER number written with leading padding bytes reads the same' do
  # 0x80 bytes carry the continuation bit and add nothing: 0x80 0x68 == 0x68.
  padded = HEADER + chunks_of(BASE_BYTES).map { |id, p| "\x80".b + ber(id) + "\x80\x80".b + ber(p.bytesize) + p }.join.b
  eq 3, loads(padded, 'padded BER ids and lengths').map_id
end

check 'an int field written as a long BER (negative, or wider than 32 bits) reads' do
  loads(with_field(BASE_BYTES, 109, 21, ber(-5)), 'negative gold')
  loads(with_field(BASE_BYTES, 109, 21, "\x90\x80\x80\x80\x05".b), 'a 5-byte BER above 32 bits')
end

check 'a bool field holding a value other than 0 or 1 reads as true' do
  ok loads(with_field(BASE_BYTES, 104, 51, "\x07".b), 'bool 7').player_through, 'any non-zero byte is true'
end

check 'present-but-empty string, byte array and 16-bit array fields load' do
  bytes = BASE_BYTES
  [[100, 11], [104, 73], [109, 13], [109, 12]].each { |cid, fid| bytes = with_field(bytes, cid, fid, ''.b) }
  loads(bytes, 'empty string/array fields')
end

check 'a 16-bit array with an odd byte count and a short double load' do
  loads(with_field(BASE_BYTES, 109, 12, "\x01\x00\x02".b), 'odd int16 array')
  loads(with_field(BASE_BYTES, 100, 1, "\x00\x00\x00".b), 'short timestamp')
end

check 'a string with invalid cp932 bytes loads, the bad bytes replaced' do
  loads(with_field(BASE_BYTES, 100, 11, "\x81".b), 'a lone cp932 lead byte')
  loads(with_field(BASE_BYTES, 100, 11, "\xff\xfe\xfd".b), 'undefined cp932 bytes')
end

check 'an RPG2000-shaped save (no 2003 fields) and an RPG2003-shaped one both load' do
  # RPG2000 omits the 2003-only fields; they read their schema default.
  st2000 = loads(BASE_BYTES, 'RPG2000 shape')
  # RPG2003 writes the extra system/hero/actor fields too; only populated ones differ.
  bytes = with_field(BASE_BYTES, 104, 91, "\x01".b)
  st2003 = loads(bytes, 'RPG2003 shape', db: party_db(rpg2003: true))
  eq st2000.map_id, st2003.map_id
end

check 'every schema field set at once (the widest valid save) round-trips and passes the typed check' do
  bytes = fully_populated_save.to_lcf
  ok bytes.bytesize > 5_000, "the full save is large (#{bytes.bytesize} bytes)"
  read = LCF::SaveData.new(StringIO.new(bytes))
  eq bytes, read.to_lcf, 'full save round trip'
  ok read.typed.check!, 'typed check passes'
end

check 'maximum-size tables load: 10000 switches and variables, 5000 items' do
  inv = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_INVENTORY })
  inv[1] = 1
  inv[2] = [1]
  inv[11] = 5000
  inv[12] = (1..5000).to_a
  inv[13] = Array.new(5000) { |i| i % 99 + 1 }
  inv[21] = 9_999_999
  sys = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
  sys[32] = Array.new(10_000) { |i| i.odd? }
  sys[34] = Array.new(10_000) { |i| i * 100 - 500_000 }
  bytes = with_chunk(with_chunk(BASE_BYTES, 109, inv.to_lcf), 101, sys.to_lcf)
  st = loads(bytes, 'maximum-size tables')
  eq 9_999_999, st.party.gold
end

# -- 2. a genuinely mismatched save is an empty slot, with a logged reason --------------------

check 'a bool field of the wrong size is an empty slot naming the field' do
  empty_slot(with_field(BASE_BYTES, 104, 51, "\x01\x00".b), 'hero.through 2 bytes',
             'Save.hero.through: invalid bool size: 2')
  empty_slot(with_field(BASE_BYTES, 104, 51, ''.b), 'hero.through empty',
             'Save.hero.through: invalid bool size: 0')
end

check 'an int field that is not a complete BER number is an empty slot naming the field' do
  empty_slot(with_field(BASE_BYTES, 109, 21, "\xff".b), 'gold 0xff',
             'Save.inventory.gold: truncated BER integer')
  empty_slot(with_field(BASE_BYTES, 100, 13, ''.b), 'hp empty', 'Save.title.hero_hp: truncated BER integer')
end

check 'a chunk that runs past the end of the file is an empty slot, not a short save' do
  empty_slot(BASE_BYTES.byteslice(0, BASE_BYTES.bytesize - 3), 'file cut inside the last chunk', 'truncated')
  empty_slot(HEADER + ber(104) + ber(100_000) + "\x01\x02".b, 'length past EOF', 'truncated')
end

check 'an absurd chunk id is an empty slot, not an allocation of that many slots' do
  empty_slot(HEADER + ber(2_000_000_000) + ber(1) + "\x01".b, 'chunk id 2e9', 'out of range')
  empty_slot(HEADER + ber(0xffff_ffff) + ber(1) + "\x01".b, 'negative chunk id', 'out of range')
  empty_slot(with_chunk(BASE_BYTES, 109, record([[2_000_000_000, "\x01".b]])), 'nested chunk id 2e9',
             'out of range')
end

check 'a table whose row count promises more rows than exist is an empty slot' do
  empty_slot(with_chunk(BASE_BYTES, 108, ber(5) + ber(1) + record([[1, 'A'.b]])),
             'row count 5, one row', 'truncated')
end

check 'empty, header-only and wrong-type files are empty slots with a reason' do
  empty_slot(''.b, 'empty file', 'truncated BER integer')
  empty_slot("\x0b".b, 'length byte only', 'Invalid header')
  empty_slot(HEADER, 'header only', 'no hero record')
  empty_slot(file_of([[100, record([])]]), 'title only', 'no hero record')
  empty_slot(BASE_BYTES.sub('LcfSaveData'.b, 'LcfDataBase'.b), 'the wrong file type', 'Invalid header')
  empty_slot('not an lcf file'.b, 'text', 'Invalid header')
end

check 'a save with a hero but no inventory is an empty slot naming the missing record' do
  empty_slot(file_of(chunks_of(BASE_BYTES).reject { |id, _| id == 109 }), 'no inventory',
             'no inventory record')
end

# -- 3. nothing crashes --------------------------------------------------------------------

# Every outcome is a state or nil plus a logged reason; nothing else escapes.
$reasons = []
def sweep(label, inputs)
  loaded = 0
  empty = 0
  unlogged = []
  inputs.each do |bytes|
    state, err = load_slot(bytes)
    if state
      loaded += 1
    else
      empty += 1
      $reasons << err.scrub.sub(/.*unreadable: /, "").strip.gsub(/\d+/, "N")
      unlogged << bytes.bytesize unless err.include?('save slot 1 unreadable: ')
    end
  end
  ok unlogged.empty?, "#{label}: empty slots without a logged reason at sizes #{unlogged.first(5).inspect}"
  puts "  #{label}: #{inputs.size} inputs, #{loaded} loaded, #{empty} empty slots"
  puts "    reasons: #{$reasons.tally.sort_by { |_, n| -n }.first(12).inspect}" if ENV["LSD_REASONS"]
end

check 'every truncation of a valid save is a loaded state or a logged empty slot' do
  sweep('truncations', (0..BASE_BYTES.bytesize).map { |n| BASE_BYTES.byteslice(0, n) })
end

check 'seeded byte corruptions are a loaded state or a logged empty slot' do
  rng = Random.new(20_261_012)
  sweep('byte corruptions', Array.new(1500) do
    b = BASE_BYTES.dup
    b.setbyte(rng.rand(b.bytesize), [0x00, 0xff, 0x7f, 0x80, rng.rand(256)].sample(random: rng))
    b
  end)
end

check 'seeded multi-byte corruptions and splices are a loaded state or a logged empty slot' do
  rng = Random.new(77)
  sweep('multi-byte corruptions', Array.new(600) do
    b = BASE_BYTES.dup
    rng.rand(1..6).times { b.setbyte(rng.rand(b.bytesize), rng.rand(256)) }
    case rng.rand(3)
    when 0 then b.byteslice(0, rng.rand(b.bytesize))
    when 1 then b.byteslice(0, rng.rand(b.bytesize)) + b.byteslice(rng.rand(b.bytesize), 40).to_s
    else b
    end
  end)
end

# -- summary -----------------------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k lsd adversarial check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k lsd adversarial check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
