#!/usr/bin/env ruby
# encoding: UTF-8
#
# The rpg2k_game requirement (scripts/coverage/test_bed.rb) against trees built
# in a temporary directory: the committed maix-hello fixture is not a test bed,
# a downloaded game is. Usage: ruby scripts/coverage/test_bed_check.rb

require 'fileutils'
require 'tmpdir'

require_relative 'test_bed'

ROOT = File.expand_path('../..', __dir__)
FIXTURE_LDB = File.join(ROOT, 'data', 'maix-hello', 'RPG_RT.ldb')

failures = 0
check = lambda do |name, &block|
  ok, detail = block.call
  puts format('  %-4s %s', ok ? 'ok' : 'FAIL', name)
  puts "       #{detail}" unless ok || detail.nil?
  failures += 1 unless ok
end

Dir.mktmpdir('test-bed-check') do |tmp|
  # Writes `relative` under tmp with the bytes of `source` (or a stub).
  place = lambda do |relative, source = nil|
    path = File.join(tmp, relative)
    FileUtils.mkdir_p(File.dirname(path))
    source ? FileUtils.cp(source, path) : File.binwrite(path, "stub\n" * 200)
  end

  check.call('no data directory: no test bed') do
    [!CoverageTestBed.rpg2k_game_present?(tmp), nil]
  end

  place.call('data/maix-hello/RPG_RT.ldb', FIXTURE_LDB)
  place.call('data/maix-hello/RPG_RT.lmt', File.join(ROOT, 'data', 'maix-hello', 'RPG_RT.lmt'))
  check.call('the committed 56-byte fixture alone is rejected') do
    size = File.size(File.join(tmp, 'data/maix-hello/RPG_RT.ldb'))
    [!CoverageTestBed.rpg2k_game_present?(tmp), "fixture is #{size} bytes"]
  end

  place.call('data/Nepheshel206beta/Nepheshel206Nbeta/RPG_RT.ldb')
  check.call('a game next to the fixture is accepted') do
    [CoverageTestBed.rpg2k_game_present?(tmp), nil]
  end

  FileUtils.rm_rf(File.join(tmp, 'data/Nepheshel206beta'))
  check.call('removing that game returns to rejecting the fixture') do
    [!CoverageTestBed.rpg2k_game_present?(tmp), nil]
  end

  place.call('data/some-other-game/RPG_RT.ldb')
  check.call('an RPG_RT.ldb under any other data directory is accepted') do
    [CoverageTestBed.rpg2k_game_present?(tmp), nil]
  end
end

puts(failures.zero? ? 'OK: rpg2k_game rejects the committed fixture and accepts a game' : "FAILED: #{failures} check(s)")
exit(failures.zero? ? 0 : 1)
