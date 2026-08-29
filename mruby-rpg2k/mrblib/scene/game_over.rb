class RPG2k
  module Scene
    # The RPG2000 Game Over screen: the database's `GameOver/<name>` picture
    # filling the screen with its game-over music playing, dismissed by the
    # Decision key, which returns to a fresh title.
    #
    # RPG_RT reaches this the same two ways this build does — the Game Over event
    # command (12420) and a battle defeat whose encounter says "game over" rather
    # than running a [Defeat] handler — so both go through Scene::GameOver rather
    # than dropping straight back to the title as they used to.
    class GameOver < Base
      # System BGM slot for Change System BGM (10660), matching a reference
      # implementation's own system-BGM enum, NOT independently confirmed
      # against genuine RPG_RT under wine — that implementation's own
      # game-over scene start plays this slot rather than the database's
      # gameover_music directly.
      SYSTEM_BGM_GAMEOVER = 6

      # `state` is the running Game::State (nil when this screen is reached
      # with no game session behind it, e.g. a bare fixture test): threaded
      # through so a Change System BGM override for the game-over slot can be
      # read back, the same override this build's battle/vehicle BGM already
      # honour. `Scene::Map#perform_game_over` / `RPG2k#show_game_over` are
      # what pass it along; the whole scene stack (and the Game::State that
      # was living on it) is otherwise gone by the time this screen exists,
      # since a game-over defeat never returns to the map.
      def initialize(parent, state = nil)
        super parent
        @game_state = state

        @picture = Sprite.new
        bmp = gameover_bitmap
        @picture.bitmap = bmp if bmp
        play_gameover_bgm
      end

      # Confirmed directly against a genuine RPG_RT.exe under wine (not just
      # the reference implementation's source this was originally ported
      # from, which claims only Decision dismisses this screen):
      # **Cancel dismisses the Game Over screen too, identically to
      # Decision.** A synthetic autostart Game Over (12420) map event
      # dropped real RPG_RT.exe onto this screen with nothing else
      # animating; a single, cleanly-isolated Escape press (sent well after
      # the screen had settled, ruling out the picture's own brief opening
      # fade as a confound) faded straight to the title screen --
      # pixel-for-pixel the same transition a single Return press produces
      # from the same starting state. So this screen behaves like every
      # other message/choice/menu window in offering Cancel as a second way
      # to back out, not the one exception that reference implementation's
      # source claimed -- a claim this wine capture directly contradicts.
      #
      # No arming/pending state of any kind (matching this screen's
      # pre-existing reasoning for Decision, which still holds): `RPG2k#
      # show_game_over` swaps `@scenes` without calling `.update` on the new
      # scene itself, so this screen's first real `#update` always lands on
      # the *next* `#main_loop` iteration, by which point that iteration's
      # own `Input.update` has already reset stale triggers from the
      # previous scene.
      def update
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

      # A Change System BGM (10660) override for the game-over slot, when the
      # running game set one and it names a file, else the database's own
      # gameover_music. Mirrors a reference implementation's own audio
      # lookup, NOT independently confirmed against genuine RPG_RT under
      # wine: the override wins only when its own filename is non-empty.
      #
      # `fadein` (cycle #203): both sources genuinely carry one, the same as
      # Scene::Map's battle/inn/vehicle BGM helpers -- the override from
      # Change System BGM's own fade-in parameter (`do_change_system_bgm`,
      # mruby-rpg2k/mrblib/interpreter.rb), the database value from
      # gameover_music's own liblcf `BGM`-struct field 2 (`fade_in`,
      # mruby-lcf/mrblib/schema.rb) -- previously read off neither and
      # dropped before reaching Audio.bgm_play. `balance` (cycle #219): the
      # same gap, for field 5 (`balance`) -- Play BGM/Play Memorized BGM and
      # (as of this same cycle) Scene::Map's own battle/inn/vehicle/Autoplay
      # BGM all re-apply their balance to `Audio.bgm_pan` unconditionally on
      # every play, but this screen's own BGM never did, so a database or
      # override pan configured for the game-over slot was silently dropped
      # too.
      def play_gameover_bgm
        name, vol, tempo, fadein, balance = gameover_bgm_override || database_gameover_bgm
        return if name.nil? || name.empty?
        Audio.bgm_play name, vol, tempo, 0, fadein
        Audio.bgm_pan balance
      rescue StandardError => e
        $stderr.puts "[RPG2k] game over BGM playback failed: #{e.message}"
      end

      def gameover_bgm_override
        return nil unless @game_state
        ov = @game_state.system_bgm[SYSTEM_BGM_GAMEOVER]
        return nil unless ov && ov[:name] && !ov[:name].to_s.empty?
        [ov[:name], ov[:volume] || 100, ov[:tempo] || 100, ov[:fadein] || 0, ov[:balance] || 50]
      end

      def database_gameover_bgm
        bgm = db.system.gameover_music
        return [nil, 100, 100, 0, 50] unless bgm
        [bgm.file, (bgm.volume || 100), (bgm.pitch || 100), (bgm.fade_in || 0), (bgm.balance || 50)]
      end
    end

  end
end
