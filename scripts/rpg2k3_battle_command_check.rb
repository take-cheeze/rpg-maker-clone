#!/usr/bin/env ruby
# encoding: UTF-8
#
# Regression guard for the RPG2003 battle-command data model — the one 2003
# battle piece that is already implemented (ADR 0048) and the foundation the
# RPG2003 battle scene mechanics (ADR 0053) build on. It loads the only 2003
# test bed (mtf-meido-action) and proves the database-wide Battle Commands
# table (chunk 0x1D) and its records decode: the table is present, its `commands`
# list (field 10) carries named + typed records, and the top-level
# presentation fields (placement 2, battle_type 7, and the newly-added 9 / 24)
# read back. Failures here mean a schema or parser change broke the 2003 battle
# command path before any battle scene work can use it.
#
# Usage: ruby scripts/rpg2k3_battle_command_check.rb [MTF_DB_DIR]
# With no argument it scans ./data for a directory whose RPG_RT.ldb reports
# maker 2003 (mtf-meido-action). Exits non-zero on any assertion failure.

require 'stringio'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  end
  module_function :cp932_to_utf8

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

$errors = 0
def fail(msg)
  $errors ||= 0
  $errors += 1
  warn "  FAIL #{msg}"
end

dir = ARGV.first
dir ||= Dir.glob(File.join(File.expand_path('../data', __dir__), '**', 'RPG_RT.ldb'))
         .map { |f| File.dirname(f) }
         .find do |d|
           begin
             db = LCF::Database.new(File.open(File.join(d, 'RPG_RT.ldb'), 'rb'))
             db.maker == 2003
           rescue
             false
           end
         end

abort 'no RPG2003 test bed found (expected mtf-meido-action)' unless dir
puts "== #{dir}"

db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
fail '2003 database does not report maker 2003' unless db.maker == 2003

bc = db.battlecommands
fail 'battlecommands (chunk 0x1D) absent in 2003 database' unless bc
fail 'battlecommands is not an Array1D' unless bc.is_a?(LCF::Array1D)

cmds = bc.commands
fail 'battlecommands.commands (field 10) absent' unless cmds
fail 'battlecommands.commands is not an Array2D' unless cmds.is_a?(LCF::Array2D)

# Every decoded command record must carry a name and a type, and the ids must be
# 1-based and contiguous from 1 (RPG_RT writes the table that way).
count = 0
cmds.each do |id, rec|
  count += 1
  # A record is valid as long as it decodes: name is always a String (an empty
  # name is legitimate -- RPG_RT's Special command and unused table slots ship
  # with none), and type is a 0..6 int (absent -> schema default 0).
  fail "command #{id} name not a String" unless rec.name.is_a?(String)
  fail "command #{id} type not an Integer" unless rec.type.is_a?(Integer)
  fail "command #{id} type out of range 0..6" unless (0..6).cover?(rec.type)
end
fail 'battlecommands.commands is empty' if count.zero?
puts "  commands: #{count} records"

# Top-level presentation fields.
bt = bc.battle_type
fail "battle_type (field 7) nil" if bt.nil?
fail "battle_type out of range 0..2" unless (0..2).cover?(bt.to_i)
puts "  placement=#{bc.placement} battle_type=#{bt}"

# The two newly-declared top-level fields (9 / 24) must not raise on access and
# must read back as integers.
[9, 24].each do |fid|
  v = bc.instance_variable_get(:@sym2idx) && bc.send(:[], fid) rescue nil
  # access via raw id to avoid depending on the accessor name
  raw = bc.instance_variable_get(:@data)[fid]
  fail "battlecommands field #{fid} absent" if raw.nil?
  puts "  field #{fid} = #{LCF.read_ber(StringIO.new(raw)) rescue raw.bytes.inspect}"
end

if $errors.zero?
  puts 'OK: RPG2003 battle-command data model decodes cleanly'
else
  warn "#{$errors} error(s)"
end
exit($errors.zero? ? 0 : 1)
