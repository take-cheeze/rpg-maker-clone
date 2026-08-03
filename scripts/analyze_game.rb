#!/usr/bin/env ruby
# encoding: UTF-8
#
# Analyse one or more RPG Maker 2000 game projects and report what data and
# event-command features they actually use, so the clone's coverage gaps can be
# prioritised from real content rather than guesswork.
#
# Like scripts/lcf_testbed_check.rb this loads the pure-Ruby LCF parser
# (mruby-lcf/mrblib/{lcf,schema}.rb) under CRuby and runs it over a game's
# RPG_RT.ldb / RPG_RT.lmt / Map*.lmu. It walks:
#   * the database common events (their packed command lists),
#   * every map event page (command list + custom move route),
# and tallies each event-command opcode and move-command id, marking which
# opcodes the runtime interpreter (mruby-rpg2k/mrblib/interpreter.rb) currently
# implements.
#
# Usage:
#   ruby scripts/analyze_game.rb [--json] GAME_DIR [GAME_DIR ...]
# With no GAME_DIR it scans ./data for directories containing an RPG_RT.ldb.
#
# Only structural, encoding-independent facts are reported, so the Windows-31J
# transcoder shim below never affects the result.

require 'stringio'
require 'json'
require 'set'

module LCF
  # uni-algo stand-in (native build uses uni-algo); mirrors lcf_testbed_check.rb.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "�")
  end
  module_function :cp932_to_utf8

  # Referenced by a lazy default in the actor schema; RPG2000 caps at 50.
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

# --- RPG2000 event-command opcode names (from liblcf's Cmd enum). -------------
# Only used for labelling the report; an unknown code is shown as its number so
# the analysis never invents a name it is unsure of.
CODE_NAMES = {
  # Editor-emitted structural no-ops: code 0 terminates a list / blank line at
  # top level, code 10 is a blank command line inside an indented block (both
  # carry no string and no parameters). RPG_RT skips them and so does the
  # interpreter (`else nil`), so they are correctly handled, not feature gaps.
  0  => 'BlankLine/End(no-op)', 10 => 'BlankLine(no-op)',
  10110 => 'ShowMessage',            20110 => 'ShowMessage(cont.)',
  10120 => 'MessageOptions',         10130 => 'ChangeFaceGraphic',
  10140 => 'ShowChoice',             20140 => 'ShowChoiceOption', 20141 => 'ShowChoiceEnd',
  10150 => 'InputNumber',
  10210 => 'ControlSwitches',        10220 => 'ControlVars',       10230 => 'TimerOperation',
  10310 => 'ChangeGold',             10320 => 'ChangeItems',       10330 => 'ChangePartyMembers',
  10410 => 'ChangeExp',              10420 => 'ChangeLevel',       10430 => 'ChangeParameters',
  10440 => 'ChangeSkills',           10450 => 'ChangeEquipment',
  10460 => 'ChangeHP',               10470 => 'ChangeSP',          10480 => 'ChangeCondition',
  10490 => 'FullHeal',               10500 => 'SimulatedAttack',
  10510 => 'ChangeHeroName',         10520 => 'ChangeHeroTitle',
  10530 => 'ChangeSpriteAssociation',10540 => 'ChangeActorFace',
  10610 => 'ChangeVehicleGraphic',   10620 => 'ChangeSystemBGM',   10630 => 'ChangeSystemSFX',
  10640 => 'ChangeSystemGraphics',   10650 => 'ChangeScreenTransitions',
  10710 => 'EnemyEncounter',         10720 => 'OpenStore',         10730 => 'ShowInn',
  10740 => 'EnterHeroName',
  10810 => 'Teleport',               10820 => 'MemorizeLocation',  10830 => 'RecallToLocation',
  10840 => 'EnterExitVehicle',       10850 => 'SetVehicleLocation',10860 => 'ChangeEventLocation',
  10870 => 'TradeEventLocations',    10910 => 'StoreTerrainID',    10920 => 'StoreEventID',
  11010 => 'EraseScreen',            11020 => 'ShowScreen',        11030 => 'TintScreen',
  11040 => 'FlashScreen',            11050 => 'ShakeScreen',       11060 => 'PanScreen',
  11070 => 'WeatherEffects',
  11110 => 'ShowPicture',            11120 => 'MovePicture',       11130 => 'ErasePicture',
  11210 => 'ShowBattleAnimation',    11310 => 'PlayerVisibility',  11320 => 'FlashSprite',
  11330 => 'MoveEvent',              11340 => 'ProceedWithMovement',11350 => 'HaltAllMovement',
  11410 => 'Wait',
  11510 => 'PlayBGM',                11520 => 'FadeOutBGM',        11530 => 'MemorizeBGM',
  11540 => 'PlayMemorizedBGM',       11550 => 'PlaySound',         11560 => 'PlayMovie',
  11610 => 'KeyInputProc',           11710 => 'ChangeMapTileset',  11720 => 'ChangePBG',
  11740 => 'ChangeEncounterRate',    11750 => 'TileSubstitution',
  11810 => 'TeleportTargets',        11820 => 'ChangeTeleportAccess',
  11830 => 'EscapeTarget',           11840 => 'ChangeEscapeAccess',
  11910 => 'OpenSaveMenu',           11930 => 'ChangeSaveAccess',
  11950 => 'OpenMainMenu',           11960 => 'ChangeMainMenuAccess',
  12010 => 'ConditionalBranch',      22010 => 'ElseBranch',        22011 => 'EndBranch',
  12110 => 'Label',                  12120 => 'JumpToLabel',
  12210 => 'Loop',                   12220 => 'BreakLoop',         22210 => 'EndLoop',
  12310 => 'EndEventProcessing',     12320 => 'EraseEvent',        12330 => 'CallEvent',
  12410 => 'Comment',                22410 => 'Comment(cont.)',
  12420 => 'GameOver',               12510 => 'ReturnToTitleScreen',
  12610 => 'ChangeClass',            12710 => 'ChangeBattleCommands',
}.freeze

MOVE_NAMES = {
  0 => 'MoveUp', 1 => 'MoveRight', 2 => 'MoveDown', 3 => 'MoveLeft',
  4 => 'MoveUpRight', 5 => 'MoveDownRight', 6 => 'MoveDownLeft', 7 => 'MoveUpLeft',
  8 => 'MoveRandom', 9 => 'MoveTowardHero', 10 => 'MoveAwayFromHero', 11 => 'MoveForward',
  12 => 'FaceUp', 13 => 'FaceRight', 14 => 'FaceDown', 15 => 'FaceLeft',
  16 => 'Turn90Right', 17 => 'Turn90Left', 18 => 'Turn180', 19 => 'Turn90RandomLR',
  20 => 'TurnRandom', 21 => 'TurnTowardHero', 22 => 'TurnAwayFromHero',
  23 => 'SwitchOn', 24 => 'SwitchOff', 25 => 'ChangeSpeed', 26 => 'ChangeFreq',
  27 => 'WalkAnimOn', 28 => 'WalkAnimOff', 29 => 'FixDirOn', 30 => 'FixDirOff',
  31 => 'Through(on)', 32 => 'Through(off)', 33 => 'StopAnimOn', 34 => 'StopAnimOff',
  35 => 'ChangeGraphic', 36 => 'PlaySoundEffect', 37 => 'Wait',
  38 => 'BeginJump', 39 => 'EndJump', 40 => 'LockFacing', 41 => 'UnlockFacing',
}.freeze

# Event-command opcodes the runtime interpreter implements with a real handler
# (mruby-rpg2k/mrblib/interpreter.rb `execute`). Structural markers the
# interpreter consumes as control flow count as supported.
SUPPORTED = [
  10110, 20110, 10120, 10130, 10140, 20140, 20141, 10210, 10220, 10230, 10310,
  10320, 10330, 10430, 10460, 10470, 10490, 12010, 22010, 22011, 12110, 12120,
  12210, 12220, 22210, 12310, 12320, 12330, 10810, 10820, 10830, 11330, 11410,
  11510, 11530, 11540, 11550, 11930, 11960,
].to_set

# Opcodes that do nothing at run time by design: developer comments and blank /
# block-structure lines. The interpreter no-ops them, which is the correct
# behaviour, so they count as "handled" and must not be reported as missing
# features (they otherwise dominate the histogram and hide the real gaps).
NOOP_BY_DESIGN = [12410, 22410, 0, 10].to_set

TRIGGER_NAMES = { 0 => 'action', 1 => 'player-touch', 2 => 'event-touch',
                  3 => 'auto-start', 4 => 'parallel' }.freeze
MOVETYPE_NAMES = { 0 => 'stationary', 1 => 'random', 2 => 'vertical',
                   3 => 'horizontal', 4 => 'toward-hero', 5 => 'away-hero',
                   6 => 'custom-route' }.freeze

class GameStats
  attr_reader :name, :cmd_hist, :move_hist, :trigger_hist, :movetype_hist,
              :db_counts, :errors, :move_event_cmds, :common_by_start
  # Bumped from analyze() via `st.maps += 1` etc., so these need writers.
  attr_accessor :maps, :map_events, :pages

  def initialize(name)
    @name = name
    @cmd_hist = Hash.new(0)
    @move_hist = Hash.new(0)
    @trigger_hist = Hash.new(0)
    @movetype_hist = Hash.new(0)
    @db_counts = {}
    @common_by_start = Hash.new(0)
    @maps = 0
    @map_events = 0
    @pages = 0
    @move_event_cmds = 0
    @errors = []
  end

  def tally_commands(cmds)
    return unless cmds
    cmds.each do |c|
      @cmd_hist[c.code] += 1
      @move_event_cmds += 1 if c.code == 11330
    end
  end

  def tally_move_route(route)
    return unless route
    cmds = route.commands rescue nil
    return unless cmds
    cmds.each { |m| @move_hist[m.command_id] += 1 }
  end
end

def count2d(v)
  n = 0
  v&.each { n += 1 }
  n
end

def analyze(dir)
  st = GameStats.new(File.basename(dir.chomp('/')))

  begin
    db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
    %i[player skill item enemy enemy_group terrain chipset battle_anime
       switch variable common_event].each do |field|
      st.db_counts[field] = (count2d(db.__send__(field)) rescue -1)
    end
    db.common_event&.each do |_id, ce|
      st.common_by_start[ce.start_term.to_i] += 1 rescue nil
      st.tally_commands(ce.event)
    end
  rescue => e
    st.errors << "RPG_RT.ldb: #{e.class}: #{e.message}"
  end

  Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
    base = File.basename(f)
    begin
      lmu = LCF::MapUnit.new(File.open(f, 'rb'))
      st.maps += 1
      lmu.events.each do |_id, ev|
        st.map_events += 1
        ev.pages.each do |_pid, pg|
          st.pages += 1
          st.trigger_hist[pg.trigger.to_i] += 1 rescue nil
          st.movetype_hist[pg.move_type.to_i] += 1 rescue nil
          st.tally_commands(pg.event_commands)
          st.tally_move_route(pg.move_route)
        end
      end
    rescue => e
      st.errors << "#{base}: #{e.class}: #{e.message}"
    end
  end

  st
end

def cmd_label(code)
  CODE_NAMES[code] || "unknown(#{code})"
end

def classify(code)
  return :impl if SUPPORTED.include?(code)
  return :noop if NOOP_BY_DESIGN.include?(code)
  :gap
end

def print_report(st)
  total = st.cmd_hist.values.sum
  impl = st.cmd_hist.select { |c, _| classify(c) == :impl }.values.sum
  noop = st.cmd_hist.select { |c, _| classify(c) == :noop }.values.sum
  handled = impl + noop
  gaps = st.cmd_hist.select { |c, _| classify(c) == :gap }
  pct = ->(n) { total.zero? ? 0 : 100.0 * n / total }

  puts "== #{st.name} =="
  puts "  maps=#{st.maps} map_events=#{st.map_events} pages=#{st.pages} " \
       "common_events=#{st.db_counts[:common_event]}"
  puts "  db: actors=#{st.db_counts[:player]} skills=#{st.db_counts[:skill]} " \
       "items=#{st.db_counts[:item]} enemies=#{st.db_counts[:enemy]} " \
       "troops=#{st.db_counts[:enemy_group]} chipsets=#{st.db_counts[:chipset]} " \
       "animations=#{st.db_counts[:battle_anime]} switches=#{st.db_counts[:switch]} " \
       "variables=#{st.db_counts[:variable]}"
  puts format("  event commands: %d total", total)
  puts format("    correctly handled: %d (%.1f%%) = implemented %d (%.1f%%) + no-op-by-design %d (%.1f%%)",
              handled, pct.call(handled), impl, pct.call(impl), noop, pct.call(noop))
  puts format("    genuine feature gaps: %d (%.1f%%) across %d distinct opcode(s)",
              gaps.values.sum, pct.call(gaps.values.sum), gaps.size)

  puts "  -- top event commands (✓ implemented · no-op-by-design ✗ gap) --"
  st.cmd_hist.sort_by { |_, n| -n }.first(25).each do |code, n|
    mark = { impl: '✓', noop: '·', gap: '✗' }[classify(code)]
    puts format("    %s %-26s %6d  (%.1f%%)", mark, cmd_label(code), n, pct.call(n))
  end

  unless gaps.empty?
    puts "  -- genuine feature gaps (unimplemented, would change behaviour) --"
    gaps.sort_by { |_, n| -n }.each do |code, n|
      puts format("    %-26s %6d", cmd_label(code), n)
    end
  end

  unless st.move_hist.empty?
    mtotal = st.move_hist.values.sum
    puts "  -- move-route commands (#{mtotal} total) top 12 --"
    st.move_hist.sort_by { |_, n| -n }.first(12).each do |id, n|
      puts format("    %-16s %6d", MOVE_NAMES[id] || "move(#{id})", n)
    end
  end

  puts "  -- event page triggers --"
  st.trigger_hist.sort.each do |t, n|
    puts format("    %-14s %6d", TRIGGER_NAMES[t] || "trigger(#{t})", n)
  end
  puts "  -- event page move types --"
  st.movetype_hist.sort.each do |t, n|
    puts format("    %-14s %6d", MOVETYPE_NAMES[t] || "movetype(#{t})", n)
  end

  unless st.errors.empty?
    warn "  !! #{st.errors.size} parse error(s):"
    st.errors.first(20).each { |e| warn "     #{e}" }
  end
  puts
end

def to_h(st)
  {
    name: st.name, maps: st.maps, map_events: st.map_events, pages: st.pages,
    db: st.db_counts, common_by_start: st.common_by_start,
    move_event_cmds: st.move_event_cmds,
    cmd_hist: st.cmd_hist.map { |c, n| [cmd_label(c), n] }.to_h,
    cmd_codes: st.cmd_hist,
    feature_gaps: st.cmd_hist.select { |c, _| classify(c) == :gap }
                    .map { |c, n| [cmd_label(c), n] }.to_h,
    noop_by_design: st.cmd_hist.select { |c, _| classify(c) == :noop }
                      .map { |c, n| [cmd_label(c), n] }.to_h,
    move_hist: st.move_hist.map { |i, n| [MOVE_NAMES[i] || i, n] }.to_h,
    triggers: st.trigger_hist.map { |t, n| [TRIGGER_NAMES[t] || t, n] }.to_h,
    move_types: st.movetype_hist.map { |t, n| [MOVETYPE_NAMES[t] || t, n] }.to_h,
    errors: st.errors,
  }
end

json = ARGV.delete('--json')
games = ARGV.dup
if games.empty?
  root = File.expand_path('../data', __dir__)
  games = Dir.glob(File.join(root, '**', 'RPG_RT.ldb')).map { |f| File.dirname(f) }.sort
end
if games.empty?
  warn 'usage: ruby scripts/analyze_game.rb [--json] GAME_DIR [GAME_DIR ...]'
  exit 1
end

stats = games.map { |g| analyze(g) }
if json
  puts JSON.pretty_generate(stats.map { |s| to_h(s) })
else
  stats.each { |s| print_report(s) }
end
