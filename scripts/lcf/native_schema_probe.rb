#!/usr/bin/env ruby
# encoding: UTF-8
# Prepare an isolated RPG_RT save/schema probe; see docs/adr/0400.
require 'stringio'
require 'fileutils'

module LCF
  def self.cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J').encode('UTF-8', invalid: :replace, undef: :replace)
  end
  def self.utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace).b
  end
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

root = File.expand_path('../..', __dir__)
%w[lcf schema lcf_file].each { |name| load File.join(root, 'mruby-lcf/mrblib', "#{name}.rb") }
source, output, scenario = ARGV
unless source && output && %w[screen vehicle-picture encounter-common boarding].include?(scenario)
  abort 'Usage: ruby scripts/lcf/native_schema_probe.rb GAME_DIR NEW_DIR screen|vehicle-picture|encounter-common|boarding'
end
abort "Output already exists: #{output}" if File.exist?(output)
%w[RPG_RT.exe RPG_RT.ldb Save01.lsd].each do |name|
  abort "Missing #{name} in #{source}" unless File.file?(File.join(source, name))
end
FileUtils.cp_r(source, output)
save = LCF::SaveData.new(File.open(File.join(output, 'Save01.lsd'), 'rb'))
hero = save[:hero]
map_id, x, y = hero[:map_id], hero[:x], hero[:y]
command = ->(code, parameters = [], string = '') { LCF::EventCommand.new(code, 0, string, parameters) }
commands = case scenario
when 'screen'
  [command.call(11070, [1, 2]), command.call(11060, [0]),
   command.call(11060, [2, 1, 4, 1, 0]),
   command.call(11320, [10001, 31, 7, 3, 25, 100, 0])]
when 'vehicle-picture', 'boarding'
  boarding = [command.call(10850, [2, 0, map_id, x, y]), command.call(10840)]
  if scenario == 'boarding'
    boarding
  else
    picture = Dir.glob(File.join(output, 'Picture', '*.png')).sort.first
    abort 'The picture probe needs a PNG in Picture/' unless picture
    name = File.basename(picture, '.png').force_encoding('Windows-31J').encode('UTF-8')
    [command.call(11070, [2, 1]), command.call(11060, [2, 2, 3, 2, 1])] + boarding +
      [command.call(11410, [30]),
       command.call(11110, [1, 0, 160, 120, 0, 100, 17, 1, 100, 100, 100, 100], name),
       command.call(11120, [1, 0, 160, 120, 0, 100, 63, 1, 100, 100, 100, 100, 0, 0, 100, 0]),
       command.call(11410, [1])]
  end
when 'encounter-common'
  hero[124] = 12345
  save[104] = hero
  database_path = File.join(output, 'RPG_RT.ldb')
  database = LCF::Database.new(File.open(database_path, 'rb'))
  common = database[25]
  event_id = 1
  common.each { |id, _row| event_id = id + 1 if id >= event_id }
  event = LCF::Array1D.new('', { elements: LCF::Schema::COMMON_EVENT })
  event[1] = 'Native LSD probe'
  event[11] = 4
  body = [command.call(11070, [1, 1]), command.call(11410, [100]), command.call(0)]
  event[21] = LCF.encode_event_commands(body).bytesize
  event[22] = body
  common[event_id] = event
  database[25] = common
  database.save_to(database_path)
  puts "Parallel common-event id: #{event_id}"
  []
end
commands += [command.call(11910), command.call(0)]
map_path = File.join(output, 'Map%04d.lmu' % map_id)
map = LCF::MapUnit.new(File.open(map_path, 'rb'))
page = LCF::Array1D.new('', { elements: LCF::Schema::MAP_EVENT_PAGE })
page[33] = 3
page[51] = LCF.encode_event_commands(commands).bytesize
page[52] = commands
pages = LCF::Array2D.new('', { elements: LCF::Schema::MAP_EVENT_PAGE })
pages[1] = page
event = LCF::Array1D.new('', { elements: LCF::Schema::MAP_EVENT })
event[1] = 'Native LSD probe'
event[2] = 1
event[3] = 1
event[5] = pages
events = LCF::Array2D.new('', { elements: LCF::Schema::MAP_EVENT })
events[1] = event
map[81] = events
map.save_to(map_path)
[113, 114, 200].each { |id| save.delete(id) }
map_events = save[:map_events]
if map_events
  map_events.delete(11)
  save[111] = map_events
end
Dir.glob(File.join(output, 'Save*.lsd')).each { |path| File.delete(path) }
save.save_to(File.join(output, 'Save01.lsd'))
puts "Prepared #{scenario} in #{output}. Load slot 1 in RPG_RT, then save to slot 2."
