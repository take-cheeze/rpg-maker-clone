# frozen_string_literal: true
# encoding: UTF-8
#
# The `rpg2k_game` requirement of scripts/coverage/report.rb, kept in its own
# file so scripts/coverage/test_bed_check.rb can run the real predicate.

module CoverageTestBed
  # Committed RPG_RT.ldb fixtures that are not a downloaded game. Each one
  # is a synthetic file, so a check that needs a real game must not be
  # satisfied by it (its nano7 and command-soak checks would pass vacuously).
  COMMITTED_FIXTURES = %w[data/maix-hello].freeze

  # True when a downloaded RPG2000/2003 game sits under root/data. Only the
  # committed fixtures are excluded, by directory, so no file-size heuristic
  # decides what counts as a game.
  def self.rpg2k_game_present?(root)
    Dir.glob(File.join(root, 'data', '**', 'RPG_RT.ldb')).any? do |path|
      relative = path[(root.length + 1)..]
      COMMITTED_FIXTURES.none? { |fixture| relative.start_with?("#{fixture}/") }
    end
  end
end
