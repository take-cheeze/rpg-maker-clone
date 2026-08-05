# The RGSS2 / RGSS3 built-ins a VX / VX Ace project's own scripts call.
#
# The schema in rgss2_data.rb declares the `RPG::*` records as pure data, which
# is all a database reader needs. The real RGSS2/RGSS3 library gives two of those
# record classes *behaviour* as well, and adds a couple of Kernel methods, and
# the stock scripts lean on both from their first frame:
#
#   * `RPG::BGM`/`BGS`/`ME`/`SE` play themselves — `$game_system.battle_bgm.play`,
#     `@map_bgm.replay`, `RPG::BGM.fade(1000)`, `RPG::SE.stop`. Measured in the
#     109 stock VX Ace sections: 19 `#play`, 6 `#fade`, 3 `#replay`, plus the
#     class-level `last`/`stop`/`fade` (docs/rpgvx-rgss-api-gap.md).
#   * `rgss_main` wraps the whole game loop in RGSS3 (`rgss_main { SceneManager
#     .run }` is the entire Main section of every VX Ace project), and `msgbox` /
#     `msgbox_p` are the RGSS2+ debug printers.
#
# All of it is plain Ruby over `RGSS::Audio`, so it is defined here rather than
# in the native gem. The Kernel methods are RGSS2/RGSS3-only; XP scripts never
# call them, so defining them globally costs the XP path nothing.
class RPGVX
  # Kept as a marker of where the behaviour below comes from, and so a caller can
  # ask which edition's built-ins are installed.
  RGSS_RUNTIME = "RGSS2/RGSS3".freeze
end

module RPG
  # Playback behaviour shared by the four audio record classes. RGSS gives each
  # of them `play`/`stop`/`fade` plus a class-side "last played" slot that the
  # save data and `replay` restore from; the differences between the four are the
  # `RGSS::Audio` entry points, which each subclass names below.
  module AudioPlayback
    # Empty name = "no music", which in RGSS stops the channel instead of
    # playing silence. Volume/pitch default to the record's own.
    def play(volume = nil, pitch = nil)
      if name.nil? || name.empty?
        self.class.stop
      else
        self.class.play_audio(name, volume || self.volume || 100,
                              pitch || self.pitch || 100)
        self.class.last = self
      end
    end

    # Play this record again from its stored position. RGSS3's `RPG::BGM#replay`
    # resumes at `pos` (the map BGM is replayed after a battle); the SDL_mixer
    # backend cannot seek, so the position is kept for the save data and the
    # track restarts. Same audible result for a looping BGM.
    def replay
      play
    end

    def stop
      self.class.stop
    end

    def fade(time)
      self.class.fade(time)
    end

    # Class-side helpers. `last` is the record most recently played on that
    # channel (RGSS3 exposes it as `RPG::BGM.last`, which the save data stores);
    # `stop` and `fade` act on the channel itself.
    module ClassMethods
      def last
        @last ||= new_empty
      end

      def last=(record)
        @last = record
      end

      def stop
        stop_audio
        @last = new_empty
      end

      def fade(time)
        fade_audio(time)
        @last = new_empty
      end

      # An "empty" record of this class: RGSS answers a nameless AudioFile for a
      # channel that has never played, so a caller can always read `.last.name`.
      def new_empty
        record = new
        record.name = ""
        record.volume = 100
        record.pitch = 100
        record
      end
    end
  end

  class BGM
    include AudioPlayback
    extend AudioPlayback::ClassMethods

    def self.play_audio(name, volume, pitch)
      RGSS::Audio.bgm_play(name, volume, pitch)
    end

    def self.stop_audio
      RGSS::Audio.bgm_stop
    end

    def self.fade_audio(time)
      RGSS::Audio.bgm_fade(time)
    end

    # RGSS3 stamps the playing position onto the record it hands back, which is
    # what a save stores so the BGM resumes where it left off (the SDL_mixer
    # backend cannot seek on replay, but the value round-trips).
    def self.last
      record = (@last ||= new_empty)
      record.pos = RGSS::Audio.bgm_pos
      record
    end
  end

  class BGS
    include AudioPlayback
    extend AudioPlayback::ClassMethods

    def self.play_audio(name, volume, pitch)
      RGSS::Audio.bgs_play(name, volume, pitch)
    end

    def self.stop_audio
      RGSS::Audio.bgs_stop
    end

    def self.fade_audio(time)
      RGSS::Audio.bgs_fade(time)
    end

    def self.last
      record = (@last ||= new_empty)
      record.pos = RGSS::Audio.bgs_pos
      record
    end
  end

  class ME
    include AudioPlayback
    extend AudioPlayback::ClassMethods

    def self.play_audio(name, volume, pitch)
      RGSS::Audio.me_play(name, volume, pitch)
    end

    def self.stop_audio
      RGSS::Audio.me_stop
    end

    def self.fade_audio(time)
      RGSS::Audio.me_fade(time)
    end
  end

  class SE
    include AudioPlayback
    extend AudioPlayback::ClassMethods

    def self.play_audio(name, volume, pitch)
      RGSS::Audio.se_play(name, volume, pitch)
    end

    def self.stop_audio
      RGSS::Audio.se_stop
    end

    # SE has no fade in RGSS; stopping is the only way to cut one short.
    def self.fade_audio(_time)
      stop_audio
    end

    # An SE is fire-and-forget: RGSS never reports a "last SE", and nothing in
    # the stock scripts asks for one, so playing does not claim the slot.
    def play(volume = nil, pitch = nil)
      return if name.nil? || name.empty?
      self.class.play_audio(name, volume || self.volume || 100,
                            pitch || self.pitch || 100)
    end
  end
end

# RGSS3 Kernel methods. Defined on Object, the way the script host defines
# load_data/save_data, so a bundled script reaches them at the top level.
class Object
  # RGSS3's game-loop wrapper: `rgss_main { SceneManager.run }` is the whole Main
  # section of a VX Ace project. The real one re-runs its block when the player
  # presses F12 (a `RGSSReset` reset) and swallows the reset otherwise; there is
  # no reset key here, so it runs the block once and returns its value. Errors
  # propagate, as they do in RGSS.
  def rgss_main
    yield
  end

  # RGSS3's "stop the game and wait" — used by the F12 reset path and by a
  # script that wants to halt without exiting. Blocking forever would hang the
  # per-frame driver, so this ends the game loop instead, which is what the
  # player sees either way.
  def rgss_stop
    raise RGSS::Timeout, "rgss_stop"
  end

  # RGSS2+ debug message boxes. There is no dialog to open here, so they go to
  # the log — visible, rather than silently dropped.
  def msgbox(*args)
    $stderr.puts "[RGSS2] msgbox: #{args.map { |a| a.to_s }.join}"
    nil
  end

  def msgbox_p(*args)
    $stderr.puts "[RGSS2] msgbox_p: #{args.map { |a| a.inspect }.join(", ")}"
    nil
  end
end
