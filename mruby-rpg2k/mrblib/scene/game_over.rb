class RPG2k
  module Scene
    # The RPG2000 Game Over screen: the database's `GameOver/<name>` picture
    # filling the screen with its game-over music playing, dismissed by a button
    # press, which returns to a fresh title.
    #
    # RPG_RT reaches this the same two ways this build does — the Game Over event
    # command (12420) and a battle defeat whose encounter says "game over" rather
    # than running a [Defeat] handler — so both go through Scene::GameOver rather
    # than dropping straight back to the title as they used to.
    class GameOver < Base
      def initialize(parent)
        super parent

        @picture = Sprite.new
        bmp = gameover_bitmap
        @picture.bitmap = bmp if bmp
        play_gameover_bgm
        # RPG_RT ignores whatever key ended the fight; requiring a *fresh* press
        # stops the button that closed the battle result from skipping the
        # screen in the same frame.
        @armed = false
      end

      def update
        unless @armed
          @armed = true unless Input.press?(Input::C) || Input.press?(Input::B)
          return
        end
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        parent.return_to_title
      end

      def dispose
        @picture.dispose if @picture
      end

      private

      # The database's game-over picture, or nil when the game names none (or the
      # file is missing) — the screen then shows plain black, which is better
      # than refusing to reach it at all.
      def gameover_bitmap
        name = db.system.gameover_name.to_s
        return nil if name.empty?
        Bitmap.new "GameOver/#{name}"
      rescue StandardError => e
        $stderr.puts "[RPG2k] game over picture '#{name}' failed to load: #{e.message}"
        nil
      end

      def play_gameover_bgm
        bgm = db.system.gameover_music
        return unless bgm
        name = bgm.file
        return if name.nil? || name.empty?
        Audio.bgm_play name, (bgm.volume || 100), (bgm.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RPG2k] game over BGM playback failed: #{e.message}"
      end
    end

  end
end
