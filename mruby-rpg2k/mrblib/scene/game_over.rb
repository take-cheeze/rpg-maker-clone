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
    #
    # Measured end to end against a genuine RPG_RT.exe under wine (cycle #251,
    # Nepheshel, reached through the *battle-defeat* route rather than the
    # synthetic 12420 event cycle #124 used: the leader's save record edited
    # to level 1 / 1 HP / no equipment so the map-2 two-slime troop — whose
    # Enemy Encounter carries defeat mode 0, "game over" — actually wipes the
    # party). What the real screen does, all of it confirmed by capture:
    # the `GameOver/<name>` picture is blitted at the screen origin at its
    # native size (never scaled or centred), the database's own
    # `gameover_music` starts the moment the screen comes up, nothing at all
    # happens until a key is pressed (no timeout), and Decision or Cancel
    # fades back to the title. See `#gameover_bitmap` / `#play_gameover_bgm` /
    # `#update` for the individual measurements.
    #
    # The one measured gap this build does NOT model: real RPG_RT *fades* this
    # screen in and out (deliberately left open, see docs/TODO.md) — it is a
    # scene-transition this engine has no counterpart for anywhere, and the
    # game-over screen's own fade is not even the standard one (~1.6-1.7 s in
    # and out, roughly three times the ~0.58 s fade every other scene
    # transition measured at).
    class GameOver < Base
      # System BGM slot for Change System BGM (10660), matching a reference
      # implementation's own system-BGM enum, NOT independently confirmed
      # against genuine RPG_RT under wine — that implementation's own
      # game-over scene start plays this slot rather than the database's
      # gameover_music directly. (That the *database* `gameover_music` is what
      # an un-overridden game-over screen plays is no longer in doubt — see
      # `#play_gameover_bgm` — but nothing has yet exercised a Change System
      # BGM override in front of a real game over to pin the slot number.)
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
      # Re-confirmed in cycle #251 on the *other* route into this screen — a
      # real party wipe in the map-2 two-slime battle rather than an injected
      # 12420 event — and widened: with the screen settled, four arrow presses
      # (Down/Up/Left/Right) and a Shift press each left it **pixel-identical**
      # (ImageMagick `compare -metric AE` = 0 against the frame before the
      # press), and so did 15 s of doing nothing at all, so there is no
      # timeout and no third dismiss key; a single Escape then faded to the
      # title, whose cursor sat on New Game. Hence exactly these two buttons,
      # and no `Input.press?`/auto-advance of any kind.
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
      #
      # Geometry and decode confirmed against a genuine RPG_RT.exe under wine
      # (cycle #251): Nepheshel's own 320x240 `GameOver/gameover.png` came back
      # from the real screen pixel-for-pixel identical to the file doubled to
      # the 640x480 capture (RMSE 1.1%, i.e. the reference X server's RGB565
      # quantisation and nothing else). Substituting a deliberately undersized
      # 100x60 probe picture for it — the only way to tell "drawn 1:1" from
      # "stretched to fill", since a 320x240 picture looks the same either way
      # — put the probe's 100x60 in the screen's top-left corner at exactly
      # 1:1 (its inner quadrant boundaries landed on logical x=50, y=30): RPG_RT
      # neither scales the picture to the screen nor centres it. So a plain
      # `Sprite` at the origin with no zoom, which is what this is, is right.
      # The same probe showed palette index 0 is drawn **opaque**: the two
      # pixels of Nepheshel's own picture that use its palette entry 0 came
      # back as that colour (49,48,49 quantised from 50,49,50), not as
      # transparent black — so the colour-keyed decode (`Bitmap.new`'s second
      # argument) must stay off here, as it is.
      #
      # Real RPG_RT probes `<name>.bmp` before `<name>.png`, and cycle #258
      # settled that this is a preference and not just a probe order: a flat
      # gradient `GameOver/gameover.bmp` dropped beside Nepheshel's own shipped
      # `gameover.png` is what the real party-wipe Game Over screen drew, with
      # the `.png` never opened at all. The RPG2000/2003 candidate list is now
      # `RGSS::Bitmap::RPG2K_EXTENSIONS` (`[bmp, png, xyz]`, installed by
      # `RPG2k#initialize`), so this `Bitmap.new` resolves the same way
      # RPG_RT does.
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
      # The *fallback* half of that — an un-overridden game over plays the
      # database's `gameover_music`, and plays it as the screen comes up — is
      # confirmed against a genuine RPG_RT.exe under wine (cycle #251): a
      # `WINEDEBUG=+file` trace of a real battle-defeat game over opens
      # `Music/die.mid` (Nepheshel's own System > game-over BGM) between the
      # killing blow's damage SE and the first `GameOver/gameover.*` probe —
      # i.e. the BGM is started before the picture is even looked for, and no
      # other music file is touched. The same trace shows **no `Sound/` file is
      # opened when the screen comes up, nor when a keypress dismisses it**
      # (this game re-opens an SE file on every play — the battle segment opens
      # 決定1.wav/打撃1.wav/ダメージ1.wav each time they sound — so an SE
      # playing here could not have been missed), which is why neither this
      # method nor `#update` plays one.
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
