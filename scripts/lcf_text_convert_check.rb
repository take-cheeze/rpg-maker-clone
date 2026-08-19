#!/usr/bin/env ruby
# encoding: UTF-8
#
# Regression test for scripts/lcf_text_convert.rb, the binary <-> YAML text
# converter for LCF project files (.ldb/.lmu/.lsd).
#
# Unlike scripts/lcf_save_roundtrip.rb (which needs a real Save*.lsd on disk),
# this builds its own synthetic .lmu/.ldb fixtures with the same
# from-scratch-Array1D technique mruby-lcf/test/lcf_test.rb uses, so it runs
# with no test-bed data required. It drives the converter as a subprocess --
# the same `ruby scripts/lcf_text_convert.rb ...` invocation a user would
# type -- rather than requiring its internals, so a CLI-argument regression
# would be caught here too.
#
# Covers:
#   1. Byte-exact round-trip (map_unit and database) through to_text/to_binary.
#   2. A semantic edit survives: change a field's text value, convert back to
#      binary, and an untouched sibling field/chunk is unaffected.
#   3. Nested :event / :move_commands fields (the two container types
#      LCF.encode gained alongside this tool) round-trip through text too.
#   4. `check` rejects an unknown field, a type mismatch, and reports every
#      problem in one run rather than stopping at the first.
#   5. `to_binary`/`check` on a map_tree document reports the documented
#      "not yet writable" limitation rather than crashing.
#
# Usage: ruby scripts/lcf_text_convert_check.rb
# Exits non-zero if any check fails.

require 'stringio'
require 'tmpdir'
require 'yaml'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end

  def utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace).force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

CONVERTER = File.expand_path('lcf_text_convert.rb', __dir__)

$failures = 0
def fail(msg)
  $failures += 1
  warn "  FAIL #{msg}"
end

def run(*args)
  out = IO.popen(['ruby', CONVERTER, *args], err: [:child, :out], &:read)
  [out, $?.exitstatus]
end

# A map_unit fixture with two events -- one carrying an authored event-command
# page (exercises :event), the other a custom move route (exercises
# :move_commands) -- so both of LCF.encode's new container types are on the
# byte-exact-round-trip path, not just scalars.
def build_map_unit_fixture
  schema = LCF::Schema::MAP_UNIT
  events_field = schema[:elements][81]
  page_field = events_field[:elements][5]

  talk_page = LCF::Array1D.new('', page_field)
  talk_page[21] = 'Chara1'
  talk_page[52] = [LCF::EventCommand.new(10120, 0, 'Hello', [1, 2]),
                    LCF::EventCommand.new(20110, 0, '', [])]
  talk_pages = LCF::Array2D.new('', page_field)
  talk_pages[1] = talk_page
  talker = LCF::Array1D.new('', events_field)
  talker[1] = 'Talker'
  talker[2] = 5
  talker[3] = 3
  talker[5] = talk_pages

  move_route_field = page_field[:elements][41]
  move_route = LCF::Array1D.new('', move_route_field)
  move_route[12] = [LCF::MoveCommand.new(0, '', 0, 0, 0),   # move_down (bare)
                     LCF::MoveCommand.new(32, '', 7, 0, 0),  # switch_on + id
                     LCF::MoveCommand.new(35, 'bell', 90, 110, 0)] # play_sound
  move_route[21] = true # repeat

  walk_page = LCF::Array1D.new('', page_field)
  walk_page[41] = move_route
  walk_pages = LCF::Array2D.new('', page_field)
  walk_pages[1] = walk_page
  walker = LCF::Array1D.new('', events_field)
  walker[1] = 'Walker'
  walker[2] = 1
  walker[3] = 1
  walker[5] = walk_pages

  events = LCF::Array2D.new('', events_field)
  events[1] = talker
  events[2] = walker

  mu = LCF::MapUnit.new
  mu[1] = 3   # chipset_id
  mu[2] = 20  # width
  mu[3] = 15  # height
  mu[81] = events
  mu
end

def build_database_fixture
  schema = LCF::Schema::DATABASE
  player_field = schema[:elements][11]
  hero = LCF::Array1D.new('', player_field)
  hero[1] = 'Hero'
  hero[7] = 1
  players = LCF::Array2D.new('', player_field)
  players[1] = hero
  db = LCF::Database.new
  db[11] = players
  db
end

Dir.mktmpdir('lcf-text-convert-check') do |dir|
  # 1 + 3. Byte-exact round-trip, including the :event / :move_commands fields.
  [['map_unit', build_map_unit_fixture, 'lmu'],
   ['database', build_database_fixture, 'ldb']].each do |name, file, ext|
    bin_path = File.join(dir, "fixture.#{ext}")
    file.save_to(bin_path)
    original = File.binread(bin_path)

    yml_path = File.join(dir, "#{name}.yml")
    out, status = run('to_text', bin_path, yml_path)
    fail("#{name} to_text failed (exit #{status}): #{out}") unless status.zero?

    rebuilt_path = File.join(dir, "#{name}_rebuilt.#{ext}")
    out, status = run('to_binary', yml_path, rebuilt_path)
    fail("#{name} to_binary failed (exit #{status}): #{out}") unless status.zero?

    rebuilt = File.binread(rebuilt_path)
    if rebuilt == original
      puts "#{name}: byte-exact round-trip OK (#{original.bytesize} bytes)"
    else
      fail "#{name}: round-trip differs (orig #{original.bytesize}B, " \
           "rebuilt #{rebuilt.bytesize}B)"
    end
  end

  # 2. Semantic edit: bump map_unit's width in the text form, rebuild, reread,
  # and confirm the edit landed while an untouched field (chipset_id) did not.
  yml_path = File.join(dir, 'map_unit.yml')
  doc = YAML.safe_load(File.read(yml_path))
  doc['data']['width'] = 42
  edited_path = File.join(dir, 'map_unit_edited.yml')
  File.write(edited_path, YAML.dump(doc))

  edited_bin = File.join(dir, 'map_unit_edited.lmu')
  out, status = run('to_binary', edited_path, edited_bin)
  fail("edit to_binary failed (exit #{status}): #{out}") unless status.zero?

  reread_yml = File.join(dir, 'map_unit_edited_reread.yml')
  run('to_text', edited_bin, reread_yml)
  reread = YAML.safe_load(File.read(reread_yml))
  if reread['data']['width'] == 42 && reread['data']['chipset_id'] == 3
    puts 'semantic edit: width changed, chipset_id untouched, both survive a reload'
  else
    fail "semantic edit did not survive reload: #{reread['data'].slice('width', 'chipset_id')}"
  end

  # 4. Schema checking: unknown field, type mismatch, and both reported
  # together in one run rather than stopping at the first.
  bad_path = File.join(dir, 'bad.yml')
  File.write(bad_path, YAML.dump({
    'type' => 'map_unit',
    'data' => { 'chipset_id' => 'not a number', 'width' => 20, 'ghost_field' => true },
  }))
  out, status = run('check', bad_path)
  named_both = out.include?('ghost_field') && out.include?('chipset_id') &&
               out.include?('expected an integer')
  if status.zero?
    fail 'check accepted a document with an unknown field and a type mismatch'
  elsif named_both
    puts "check: rejected an unknown field and a type mismatch, " \
         "both reported -- #{out.lines.size} line(s)"
  else
    fail "check's error output did not name both problems: #{out}"
  end

  good_path = File.join(dir, 'good.yml')
  File.write(good_path, YAML.dump({ 'type' => 'map_unit', 'data' => { 'chipset_id' => 1 } }))
  out, status = run('check', good_path)
  if status.zero?
    puts 'check: accepts a schema-valid document'
  else
    fail "check rejected a valid document: #{out}"
  end

  # 5. map_tree is documented as text-exportable but not yet binary-writable;
  # to_binary/check must say so plainly rather than raising.
  tree_path = File.join(dir, 'tree.yml')
  File.write(tree_path, YAML.dump({ 'type' => 'map_tree', 'data' => {} }))
  out, status = run('to_binary', tree_path, File.join(dir, 'tree.lmt'))
  if status.zero?
    fail 'to_binary silently accepted a map_tree document -- the writer does not exist yet'
  elsif out.include?('not yet writable')
    puts 'map_tree to_binary: reports the documented limitation rather than crashing'
  else
    fail "map_tree to_binary failed for the wrong reason: #{out}"
  end
end

if $failures.zero?
  puts 'lcf text convert check: all checks passed'
  exit 0
else
  warn "lcf text convert check: #{$failures} check(s) FAILED"
  exit 1
end
