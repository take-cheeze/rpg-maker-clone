module RGSS
  class Timeout < StandardError; end

  # Emit a warning only the first time it is raised. Warning on every call would
  # flood the log from within the game loop, so each distinct message is
  # reported once.
  @warned_once = {}
  def self.warn_once(message)
    return if @warned_once[message]
    @warned_once[message] = true
    $stderr.puts "[RGSS] #{message}"
  end

  # Warn once that an unimplemented stub method was called.
  def self.warn_stub(name)
    warn_once("#{name} is not implemented yet (stub, does nothing)")
  end

  # Color, Rect, Table and Tone are implemented in C (see src/lib.cxx).

  # The game's encrypted archive, for assets that are not on disk.
  #
  # A released RPG Maker game ships one Game.rgssad / .rgss2a / .rgss3a holding
  # its whole tree — Data/ *and* Graphics/ and Audio/ — with nothing loose. The
  # data layers open the archive themselves to read Data/, but assets are asked
  # for by name from anywhere (`Cache.tileset(n)` -> `Bitmap.new("Graphics/...")`
  # deep inside a game's own scripts), with no handle to thread through. So each
  # maker's boot shell registers its archive here once and the loaders consult
  # it after a loose file misses — loose shadows packed, as in RGSS.
  #
  # Anything answering `read(name) -> String or nil` will do; in practice it is
  # an RPGXP::RGSSAD. nil means an unpacked project.
  class << self
    attr_accessor :asset_archive
  end

  # The mean R/G/B of the rendered frame, sampled on an 8px grid (a full
  # per-pixel walk through get_pixel would take seconds). nil when the backend
  # cannot snapshot. This is the measurement ADR 0021 used to prove the RPG2000
  # fade reached the display, available to any caller now that
  # Graphics.snap_to_bitmap exists.
  #
  # With a region it means only that part of the frame, which is what tells a
  # *shaped* change from a uniform one: a flat fade moves every region together,
  # a wipe does not.
  def self.frame_mean(x0 = 0, y0 = 0, width = nil, height = nil)
    bmp = Graphics.snap_to_bitmap
    return nil if bmp.nil?
    x1 = width.nil? ? bmp.width : x0 + width
    y1 = height.nil? ? bmp.height : y0 + height
    x1 = bmp.width if x1 > bmp.width
    y1 = bmp.height if y1 > bmp.height
    r = 0
    g = 0
    b = 0
    n = 0
    y = y0
    while y < y1
      x = x0
      while x < x1
        c = bmp.get_pixel(x, y)
        r += c.red.to_i
        g += c.green.to_i
        b += c.blue.to_i
        n += 1
        x += 8
      end
      y += 8
    end
    bmp.dispose
    return nil if n.zero?
    [r / n, g / n, b / n]
  end

  # Prove the viewport screen effects actually reach the display.
  #
  # Every effect below is native rendering that no unit test can see: the test
  # binary has no display, so a Viewport cannot even be constructed there. The
  # failure mode that leaves is the dangerous one — the code runs, the values are
  # stored, and the screen never changes (exactly what happened to an earlier
  # RPG2000 screen-tint attempt, see docs/TODO.md). So this drives the real
  # renderer on a real display and *measures* the frame: grey screen, then a red
  # colour overlay, then an additive-blue tone, each against the last, and
  # finally a freeze/transition round trip.
  #
  # Run by `rpg_maker_clone --rgss_effect_probe` (under xvfb in CI). Returns true
  # when every effect moved the pixels it should.
  def self.effect_probe
    # Take the screen size from a snapshot rather than Graphics.width/height:
    # those are the values a game's resize_screen set, and there is no game here
    # — the sprite has to cover what is actually on the display. Doubles as the
    # check that this backend can snapshot at all.
    shape = Graphics.snap_to_bitmap
    if shape.nil?
      $stderr.puts "[RGSS-PROBE] snap_to_bitmap unavailable on this backend"
      return false
    end
    w = shape.width
    h = shape.height
    shape.dispose

    viewport = Viewport.new(0, 0, w, h)
    bitmap = Bitmap.new(w, h)
    bitmap.fill_rect(0, 0, w, h, Color.new(128, 128, 128, 255))
    sprite = Sprite.new(viewport)
    sprite.bitmap = bitmap
    Graphics.update
    base = frame_mean

    viewport.color = Color.new(255, 0, 0, 128)
    viewport.update
    Graphics.update
    colored = frame_mean

    viewport.color = Color.new(0, 0, 0, 0)
    viewport.tone = Tone.new(0, 0, 255, 0)
    viewport.update
    Graphics.update
    toned = frame_mean

    viewport.tone = Tone.new(0, 0, 0, 0)
    viewport.update

    # The scene change: freeze the grey screen, then take the scene away — as a
    # game does when it swaps scenes — and dissolve. `cleared` is the empty
    # screen the dissolve runs over, `mid` is a frame from inside it (sampled by
    # the hook below, since transition blocks until it is done) and `after` is
    # where it ended. Between them they pin down both halves: the frozen still
    # really goes up over the new scene, and it really comes down again.
    Graphics.freeze
    sprite.visible = false
    Graphics.update
    cleared = frame_mean

    $rgss_probe_mid = nil
    class << Graphics
      alias_method :_probe_update, :update
      def update
        _probe_update
        $rgss_probe_mid = RGSS.frame_mean if $rgss_probe_mid.nil?
      end
    end
    Graphics.transition(4)
    class << Graphics
      alias_method :update, :_probe_update
    end
    mid = $rgss_probe_mid
    after = frame_mean

    # The transition-*graphic* form: a still that gives way in the shape of a
    # map rather than fading flat, which is what a game's battle transition and
    # Pray for You's opening use. Driven at the pixel level — Bitmap#
    # _transition_alpha is exactly what Graphics.transition calls once per frame
    # — because the thing that has to be proved is that the per-pixel alpha it
    # writes reaches the display, and a flat fade would move the whole frame
    # together. Half a screen apart is the measurement: dark map values give way
    # first, so at the halfway point the dark side is gone and the light side is
    # still standing.
    wipe_left, wipe_right = transition_shape_probe(w, h)

    $stderr.puts "[RGSS-PROBE] base=#{base.inspect} color=#{colored.inspect} " \
                 "tone=#{toned.inspect} cleared=#{cleared.inspect} " \
                 "mid=#{mid.inspect} after=#{after.inspect} " \
                 "wipe=#{wipe_left.inspect}/#{wipe_right.inspect}"

    ok = true
    # A half-opaque red overlay pushes red up and the other channels down.
    unless colored[0] > base[0] + 20 && colored[2] < base[2] - 20
      $stderr.puts "[RGSS-PROBE] FAIL Viewport#color did not tint the frame"
      ok = false
    end
    # An additive blue tone pushes blue up and leaves red alone.
    unless toned[2] > base[2] + 20
      $stderr.puts "[RGSS-PROBE] FAIL Viewport#tone did not tint the frame"
      ok = false
    end
    if (cleared[0] - base[0]).abs < 20
      $stderr.puts "[RGSS-PROBE] FAIL hiding the sprite did not change the frame"
      ok = false
    else
      # Mid-dissolve the still is partly transparent, so the frame sits between
      # the frozen screen and the scene behind it.
      unless mid && (mid[0] - cleared[0]).abs > 20 && (mid[0] - base[0]).abs > 8
        $stderr.puts "[RGSS-PROBE] FAIL Graphics.transition did not show the " \
                     "frozen screen"
        ok = false
      end
      if (after[0] - cleared[0]).abs > 8
        $stderr.puts "[RGSS-PROBE] FAIL Graphics.transition left the frozen " \
                     "screen up"
        ok = false
      end
    end
    # The still is red and the screen behind it is not, so the side still
    # covered reads far redder than the side already given way. Equal halves
    # would mean the map was ignored and this dissolved uniformly.
    unless wipe_left && wipe_right && wipe_right[0] > wipe_left[0] + 40
      $stderr.puts "[RGSS-PROBE] FAIL Graphics.transition's transition graphic " \
                   "did not shape the dissolve"
      ok = false
    end

    # Graphics.brightness=: the grey sprite (still up, per Graphics.transition
    # above leaving it visible = false -- bring it back first) darkened toward
    # black, then restored, against the same base frame_mean read at the top.
    sprite.visible = true
    Graphics.update
    Graphics.brightness = 0
    Graphics.update
    dark = frame_mean
    Graphics.brightness = 255
    Graphics.update
    restored = frame_mean
    $stderr.puts "[RGSS-PROBE] dark=#{dark.inspect} restored=#{restored.inspect}"
    unless dark[0] < base[0] - 40 && dark[1] < base[1] - 40 && dark[2] < base[2] - 40
      $stderr.puts "[RGSS-PROBE] FAIL Graphics.brightness=0 did not darken the frame"
      ok = false
    end
    if (restored[0] - base[0]).abs > 10
      $stderr.puts "[RGSS-PROBE] FAIL Graphics.brightness=255 did not restore the frame"
      ok = false
    end

    sprite.dispose
    bitmap.dispose
    viewport.dispose
    ok = false unless window_probe
    ok = false unless windowskin_rect_probe
    $stderr.puts "[RGSS-PROBE] #{ok ? "ok" : "failed"}"
    ok
  end

  # Half-dissolve a solid still through a left-to-right gradient and answer the
  # mean of the quarter-screen at each edge. Called by effect_probe; kept
  # separate because it is a self-contained little scene of its own.
  #
  # The gradient is the simplest transition graphic there is — black on the left
  # (gives way first), white on the right (last) — which makes the expected
  # result a statement rather than a threshold: at the halfway point one edge is
  # gone and the other is not.
  def self.transition_shape_probe(w, h)
    still = Bitmap.new(w, h)
    still.fill_rect(0, 0, w, h, Color.new(255, 0, 0, 255))
    map = Bitmap.new(w, h)
    x = 0
    while x < w
      shade = w > 1 ? 255 * x / (w - 1) : 0
      map.fill_rect(x, 0, 1, h, Color.new(shade, shade, shade, 255))
      x += 1
    end
    shaped = still._transition_alpha(map, 0.5, 40 / 255.0)
    cover = Sprite.new
    cover.bitmap = still
    cover.z = Graphics::TRANSITION_Z
    Graphics.update
    edge = w / 4
    left = shaped ? frame_mean(0, 0, edge, h) : nil
    right = shaped ? frame_mean(w - edge, 0, edge, h) : nil
    cover.dispose
    still.dispose
    map.dispose
    Graphics.update
    [left, right]
  end

  # Prove RGSS::Window is the native widget and that it draws.
  #
  # This exists because it silently was not. Every maker gem reopens the shared
  # RGSS namespace and loads after mruby-rgss, so a class one of them defines
  # under RGSS replaces this one for the whole process — which is what RPG2000's
  # window did, leaving `Window.new` returning an object with no LVGL object
  # behind it and `window_refresh` returning early forever. Nothing in-tree
  # noticed, because nothing in-tree constructs an RGSS::Window: only a real
  # XP/VX game's own scripts do (`Window_Base < Window`), through the script
  # host.
  #
  # So: build one on an empty screen with a solid-blue background tile in its
  # skin, and require that it is alive and that it covers the area it should.
  def self.window_probe
    skin = Bitmap.new(192, 128)
    # The windowskin layout the native drawing reads: background tile at
    # (0,0,128,128), frame at (128,0,64,64). Only the background is filled, so
    # the frame contributes nothing and the measurement is pure area.
    skin.fill_rect(0, 0, 128, 128, Color.new(0, 0, 255, 255))

    win = Window.new(0, 0, 320, 240)
    alive = !win.disposed?
    win.windowskin = skin
    Graphics.update
    drawn = frame_mean

    # RGSS2/RGSS3 openness: the window unrolls from its centre line, so the area
    # it covers scales with the value. Half-open must measure about half.
    win.openness = 128
    Graphics.update
    half = frame_mean

    win.openness = 0
    Graphics.update
    closed = frame_mean

    win.openness = 255
    win.tone = Tone.new(255, 0, 0, 0)
    Graphics.update
    toned = frame_mean

    $stderr.puts "[RGSS-PROBE] window alive=#{alive} drawn=#{drawn.inspect} " \
                 "half=#{half.inspect} closed=#{closed.inspect} " \
                 "toned=#{toned.inspect}"

    ok = true
    unless alive
      $stderr.puts "[RGSS-PROBE] FAIL Window.new produced no native object — " \
                   "RGSS::Window has been replaced by another gem's class"
      ok = false
    end
    unless drawn[2] > 20
      $stderr.puts "[RGSS-PROBE] FAIL the window did not draw"
      ok = false
    end
    if ok
      # Generous bounds: what is checked is that openness *scales the drawn
      # height*, not the exact ratio.
      unless half[2] > drawn[2] / 4 && half[2] < drawn[2] * 3 / 4
        $stderr.puts "[RGSS-PROBE] FAIL openness=128 covered #{half[2]} of " \
                     "#{drawn[2]}, expected roughly half — the open/close " \
                     "animation is not drawn"
        ok = false
      end
      unless closed[2].zero?
        $stderr.puts "[RGSS-PROBE] FAIL openness=0 still drew something"
        ok = false
      end
      # An additive red tone over the blue background lifts red.
      unless toned[0] > drawn[0] + 20
        $stderr.puts "[RGSS-PROBE] FAIL Window#tone did not tint the background"
        ok = false
      end
    end
    win.dispose
    skin.dispose
    ok
  end

  # Prove the RMXP windowskin *source rectangles* are the right ones.
  #
  # window_probe above deliberately uses a flat skin, so it measures area and
  # nothing else — every source rect could be wrong and it would still pass.
  # The constants they encode were best-effort until a real game exercised them,
  # and a game with a real windowskin still would not say *which* rect was
  # misread: a wrong corner offset looks like a slightly odd border.
  #
  # So paint each source region its own primary and read back where it landed.
  # RMXP's layout, as the native drawing reads it: the 128x128 background tile
  # at (0,0), and a 64x64 frame at (128,0) 9-sliced with 16px corners — so the
  # frame's four corners sit at (128,0), (176,0), (128,48) and (176,48), and its
  # top edge is the 32px-wide strip between them at (144,0).
  def self.windowskin_rect_probe
    w = 320
    h = 240
    b = 16
    skin = Bitmap.new(192, 128)
    skin.fill_rect(0, 0, 128, 128, Color.new(0, 255, 0, 255))     # background
    skin.fill_rect(128, 0, b, b, Color.new(255, 0, 0, 255))       # frame TL
    skin.fill_rect(176, 0, b, b, Color.new(0, 0, 255, 255))       # frame TR
    skin.fill_rect(128, 48, b, b, Color.new(255, 255, 255, 255))  # frame BL
    skin.fill_rect(176, 48, b, b, Color.new(255, 255, 0, 255))    # frame BR
    skin.fill_rect(144, 0, 32, b, Color.new(255, 0, 255, 255))    # frame top

    win = Window.new(0, 0, w, h)
    win.windowskin = skin
    Graphics.update

    # Each region of the drawn window, and the colour its source rect should
    # have put there.
    # Sample inside the corner, so a one-off cannot average two regions.
    c = b - 2
    want = [
      ['top-left', frame_mean(1, 1, c, c), [255, 0, 0]],
      ['top-right', frame_mean(w - b + 1, 1, c, c), [0, 0, 255]],
      ['bottom-left', frame_mean(1, h - b + 1, c, c), [255, 255, 255]],
      ['bottom-right', frame_mean(w - b + 1, h - b + 1, c, c), [255, 255, 0]],
      ['top edge', frame_mean(w / 2, 1, 32, c), [255, 0, 255]],
      ['background', frame_mean(w / 2, h / 2, 32, 32), [0, 255, 0]],
    ]
    ok = true
    want.each do |name, got, exp|
      if got.nil?
        $stderr.puts "[RGSS-PROBE] windowskin: no frame to sample"
        ok = false
        break
      end
      $stderr.puts "[RGSS-PROBE] windowskin #{name}=#{got.inspect} " \
                   "want~#{exp.inspect}"
      # Generous: the check is which source rect landed here, and the six
      # answers are far apart in colour space, so a loose threshold cannot
      # confuse two of them.
      3.times do |i|
        hi = exp[i] > 127
        if hi ? got[i] < 128 : got[i] > 127
          $stderr.puts "[RGSS-PROBE] FAIL windowskin #{name} drew " \
                       "#{got.inspect}, expected about #{exp.inspect} — the " \
                       'source rect for that region is wrong'
          ok = false
        end
      end
    end
    win.dispose
    skin.dispose
    ok
  end

  # A 16-bit mono PCM WAV of `ms` milliseconds of a quiet square wave, built
  # here so the audio probe below needs no fixture on disk. Long enough that a
  # few frames of playback land inside it.
  def self.probe_wav(ms = 2000)
    rate = 11025
    samples = rate * ms / 1000
    pcm = []
    i = 0
    while i < samples
      # ~440Hz at a low amplitude; the dummy audio driver discards it anyway,
      # but a real device should not be handed a full-scale tone.
      pcm << (((i * 2 / (rate / 440)) % 2).zero? ? 2000 : -2000)
      i += 1
    end
    data = pcm.pack("s<*")
    header = ["RIFF"].pack("a4") + [36 + data.bytesize].pack("V") +
             ["WAVEfmt "].pack("a8") + [16].pack("V") +
             [1, 1].pack("v2") + [rate, rate * 2].pack("V2") +
             [2, 16].pack("v2") + ["data"].pack("a4") + [data.bytesize].pack("V")
    header + data
  end

  # Prove audio packed into an encrypted archive actually reaches the mixer.
  #
  # Like the render probe above, this exists because the interesting half is
  # native and invisible to `mruby-rgss/test`: that binary installs no audio
  # backend, so every Audio call there is a no-op and a broken memory path would
  # look exactly like a working one. Here the real SDL_mixer backend runs (under
  # SDL_AUDIODRIVER=dummy in CI, which decodes and mixes with no sound card).
  #
  # It is an A/B/A. The same sound is played first from a loose file, then
  # stopped, then played out of an archive:
  #
  #   loose   > 0   the observable works at all (an SDL_mixer older than 2.6
  #                 cannot report a position, and would make everything below
  #                 look like a failure to play rather than passing vacuously)
  #   stopped = 0   nothing is playing between the arms
  #   packed  > 0   the archived sound really started
  #
  # The middle step is the one that earns the others. Without it the packed arm
  # passes against an *empty* archive, because the position it reads is the
  # loose track's — measured, not assumed: that is exactly what this probe did
  # before Audio.bgm_pos learned to check Mix_PlayingMusic().
  #
  # Run by `rpg_maker_clone --rgss_audio_probe`. Returns true when both play.
  def self.audio_probe
    wav = probe_wav
    ok = true

    path = "rgss-audio-probe.wav"
    File.open(path, "wb") { |io| io.write(wav) }
    Audio.bgm_play(path)
    loose = wait_for_bgm_pos
    Audio.bgm_stop
    Graphics.update
    stopped = Audio.bgm_pos

    # RGSS3's Audio.bgm_play pos (mid-track resume): seek 1000ms into the 2s
    # probe tone and check bgm_pos reads back near there rather than near 0.
    # Informational, not a pass/fail gate -- Mix_SetMusicPosition's decoder
    # support varies (solid for OGG/FLAC, weaker for MOD/MIDI/some WAV
    # decoders), and #bgm_play already falls back to playing from the
    # beginning when it fails, exactly as it did before this existed. A
    # decoder that cannot seek here is a real, known limitation, not a broken
    # build.
    Audio.bgm_play(path, 100, 100, 1000)
    seek_got = wait_for_bgm_pos
    Audio.bgm_stop
    Graphics.update

    # A Music Effect interrupting the BGM resumes it where it left off once
    # the effect ends, not from the beginning (real RGSS3 behaviour; see
    # me_stop -> replay_bgm in src/sdl_audio.cxx, which now threads the BGM's
    # own captured position through the same seek this probe measured above).
    # Informational, same reasoning as the seek checks above.
    Audio.bgm_play(path)
    # Run well past wait_for_bgm_pos's first nonzero read: pre_me and
    # me_resumed both being small numbers could look like "resumed" even if
    # the BGM had actually restarted, so give the BGM real ground to have
    # covered before interrupting it.
    30.times { Graphics.update }
    pre_me = Audio.bgm_pos
    Audio.me_play(path)
    5.times { Graphics.update }
    Audio.me_stop
    me_resumed = wait_for_bgm_pos
    Audio.bgm_stop
    Graphics.update
    File.delete(path) if File.exist?(path)

    archive = Object.new
    entries = { "Audio/BGM/Probe.wav" => wav, "Audio/SE/Beep.wav" => wav }
    archive.instance_variable_set(:@entries, entries)
    def archive.read(name)
      @entries[name]
    end
    previous = asset_archive
    self.asset_archive = archive
    begin
      # The name a game uses: no folder, no extension. Finding it means the
      # candidate crossing in Audio.play_packed works, not just the decoder.
      Audio.bgm_play("Probe")
      packed = wait_for_bgm_pos
      Audio.se_play("Beep")
      Audio.bgm_stop
      Graphics.update

      # The same seek, through the packed/archived path this time (a released
      # game's whole Audio/ tree is packed, so this -- not the loose path
      # above -- is what an actual VX Ace game's mid-track resume reaches).
      Audio.bgm_play("Probe", 100, 100, 1000)
      packed_seek_got = wait_for_bgm_pos
      Audio.bgm_stop
    ensure
      self.asset_archive = previous
    end

    $stderr.puts "[RGSS-AUDIO] loose=#{loose} stopped=#{stopped} " \
                 "seek_requested=1000 seek_got=#{seek_got} packed=#{packed} " \
                 "packed_seek_got=#{packed_seek_got} pre_me=#{pre_me} " \
                 "me_resumed=#{me_resumed}"
    if loose.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL a loose file did not play (no audio " \
                   "device, or this SDL_mixer cannot report a position) — the " \
                   "packed result proves nothing either way"
      ok = false
    elsif !stopped.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL bgm_pos still reports #{stopped} after " \
                   "bgm_stop, so it cannot tell the two arms apart"
      ok = false
    elsif packed.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL archived BGM did not reach the mixer"
      ok = false
    end
    $stderr.puts "[RGSS-AUDIO] #{ok ? "ok" : "failed"}"
    ok
  end

  # Run frames until the BGM reports a position, and answer it (0 if it never
  # does). Frames, not sleeps: Graphics.update is what drives the audio
  # backend's per-frame work.
  def self.wait_for_bgm_pos(frames = 120)
    n = 0
    while n < frames
      Graphics.update
      pos = Audio.bgm_pos
      return pos if pos > 0
      n += 1
    end
    0
  end

  class Bitmap
    # RGSS resolves a bare asset name against several image formats, and the RPG
    # Maker XP RTP genuinely mixes them: its windowskins and charsets are .png
    # while its title backgrounds are .jpg, so a png-only search left every XP
    # title screen on the fallback background (found by
    # scripts/compare-rpgxp-wine.bash). stb decodes JPEG, so both spellings of
    # the extension are just more candidates.
    EXTENSIONS = [:png, :jpg, :jpeg, :xyz, :bmp].freeze

    # Raised when a String load resolves to nothing loadable. Carries the two
    # halves of the message separately so a caller that already names the file
    # -- RPG::Cache logs every asset it stands a blank in for -- can report just
    # the reason instead of printing the path twice. A RuntimeError, which is
    # what `raise "..."` used to produce here, so `rescue` clauses around
    # Bitmap.new keep working.
    class LoadError < RuntimeError
      def initialize(path, reason)
        @path = path
        @reason = reason
        super("Failed to init bitmap: #{path} (#{reason})")
      end

      attr_reader :path, :reason
    end

    def initialize f, s = nil
      if f.kind_of? String
        # Forget the previous load's diagnostics, so a failure below reports
        # this file's reason rather than some earlier image's.
        Bitmap._begin_load
        i = self._init_file(f, s)
        [GAME_DIR, RTP_DIR].each do |d|
          next if d.nil? || d.empty?
          i = self._init_file("#{d}/#{f}", s) unless i
          EXTENSIONS.each do |ext|
            i = self._init_file("#{d}/#{f}.#{ext}", s) unless i
          end
        end
        # A released game packs its whole Graphics/ tree into the encrypted
        # archive with nothing loose on disk, so try that last — loose files
        # shadow the archive, which is what RGSS itself does.
        i = init_from_archive(f, s) unless i
        raise LoadError.new(f, Bitmap.failure_reason(f)) unless i
      else
        self._init_size(f, s)
      end
    end

    # Why the load of `f` failed, for the exception #initialize raises.
    #
    # Two quite different failures used to read the same way. A file that was
    # found and rejected by a decoder has a real reason to report — an XYZ's
    # "bad dist" zlib error, say — and that is what `_load_error` /
    # `_stbi_error` carry. A name that matched nothing anywhere never reached a
    # decoder, and reporting those globals then quotes some *earlier* image's
    # failure: in practice always stb's "no SOI", because stb tries JPEG first
    # and leaves that complaint behind after every successful PNG. Released
    # games are full of this case — they reference the RTP's graphics without
    # packing them — so a missing RTP looked like a corrupt JPEG.
    #
    # `_decoder_ran?` tells the two apart; when nothing was decoded, name the
    # places that were searched instead, since which of them is empty is the
    # actual diagnosis.
    def self.failure_reason(f)
      if _decoder_ran?
        detail = _load_error
        detail = _stbi_error if detail.nil? || detail.empty?
        return detail unless detail.nil? || detail.empty?
        return "no decoder recognised the file"
      end

      where = []
      where << "GAME_DIR \"#{GAME_DIR}\"" unless GAME_DIR.nil? || GAME_DIR.empty?
      where << if RTP_DIR.nil? || RTP_DIR.empty?
                 "no RTP installed (RTP_DIR is empty)"
               else
                 "RTP_DIR \"#{RTP_DIR}\""
               end
      where << if RGSS.asset_archive.nil?
                 "no encrypted archive registered"
               else
                 "not in the encrypted archive"
               end
      "not found (tried .#{EXTENSIONS.join("/.")}): #{where.join("; ")}"
    end

    # Font used by #draw_text. Created lazily from the current defaults.
    def font
      @font ||= Font.new
    end

    def font=(f)
      @font = f
    end

    private

    # Decode `f` out of the game's encrypted archive, if one is registered (see
    # RGSS.asset_archive). Entry names are project-relative with the extension
    # spelled out, so the same candidate list the loose-file search uses applies
    # here — the archive itself normalises the '/' separators.
    #
    # Best effort: a broken archive must not take down a Bitmap.new that would
    # otherwise raise its own diagnostic, so the read failure is logged and
    # treated as a miss.
    def init_from_archive(f, s)
      archive = RGSS.asset_archive
      return nil if archive.nil?
      bytes = archive.read(f)
      if bytes.nil?
        EXTENSIONS.each do |ext|
          bytes = archive.read("#{f}.#{ext}")
          break if bytes
        end
      end
      return nil if bytes.nil?
      self._init_memory(bytes, s)
    rescue StandardError => e
      $stderr.puts "[RGSS] archive read failed for #{f}: #{e.message}"
      nil
    end
  end

  # RGSS Font. Bitmap#draw_text rasterises with the game's TrueType font (found
  # under the project's Fonts/ folder, selected by #name and sized by #size,
  # honouring bold/italic/outline/shadow and the colours) and falls back to the
  # built-in shinonome bitmap font when no font file is available. Only the
  # attributes scripts read/write are modelled here.
  class Font
    @default_name = "Arial"
    @default_size = 22
    @default_bold = false
    @default_italic = false
    @default_shadow = false
    @default_outline = true
    @default_color = Color.new(255, 255, 255, 255)
    @default_out_color = Color.new(0, 0, 0, 128)
    # Font file used when the project ships none. See #default_path below.
    @default_path = nil

    class << self
      attr_accessor :default_name, :default_size, :default_bold,
                    :default_italic, :default_shadow, :default_outline,
                    :default_color, :default_out_color

      # Path to a font file draw_text falls back to when the project itself
      # ships none — nil (no fallback) unless a runtime sets it. A font found
      # under the project's own Fonts/ still wins; this is only reached when
      # there is nothing there.
      #
      # Opt-in per maker, because there is no single right answer: RPG Maker
      # XP/VX want a real TrueType face at the size the window asked for, so
      # their boot points this at RGSS.default_font_path (the bundled default
      # font, assets/fonts). RPG2000 leaves it nil — its text renders with the
      # built-in shinonome bitmap font, whose metrics match RPG_RT's MS Gothic
      # and which the render-parity comparisons are checked against.
      attr_accessor :default_path

      def exist?(name)
        true
      end
    end

    attr_accessor :name, :size, :bold, :italic, :outline, :shadow,
                  :color, :out_color

    def initialize(name = Font.default_name, size = Font.default_size)
      @name = name
      @size = size
      @bold = Font.default_bold
      @italic = Font.default_italic
      @shadow = Font.default_shadow
      @outline = Font.default_outline
      c = Font.default_color
      @color = Color.new(c.red, c.green, c.blue, c.alpha)
      oc = Font.default_out_color
      @out_color = Color.new(oc.red, oc.green, oc.blue, oc.alpha)
    end
  end

  # RGSS Plane: a tiling, scrolling full-viewport bitmap (map parallax / fog).
  # The tiling render is native (src/lib.cxx creates an lv_canvas the size of the
  # viewport and fills it by tiling the bitmap with the ox/oy scroll — see
  # plane_init/plane_retile); `initialize`, `bitmap=`, `ox=`, `oy=`, `opacity=`,
  # `z=`, `visible`/`visible=`, `dispose`/`disposed?` are all native. This
  # reopening adds the plain readers plus the properties the native renderer does
  # not yet honour visually (zoom, blend mode, tone, colour) — stored so scripts
  # that set them run (tracked in docs/rpgxp-rgss-api-gap.md).
  class Plane
    attr_reader :bitmap, :ox, :oy, :z, :viewport
    # `opacity=`, `tone=`, `color=`, `blend_type=` and `zoom_x=`/`zoom_y=` are all
    # native (src/lib.cxx): opacity/blend map onto the plane canvas's LVGL object,
    # and tone/colour/zoom are baked into the tiled buffer by plane_retile (zoom
    # samples the source at the reciprocal rate). The readers below return the set
    # values; native #initialize does not set these ivars, so they fall back to
    # RGSS defaults here.

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def zoom_x
      @zoom_x.nil? ? 1.0 : @zoom_x
    end

    def zoom_y
      @zoom_y.nil? ? 1.0 : @zoom_y
    end

    def blend_type
      @blend_type || 0
    end

    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    def color
      @color ||= Color.new(0, 0, 0, 0)
    end
  end

  class Sprite
    attr_reader :bitmap

    # RGSS3 (VX Ace) added these over XP/VX's Sprite: the graphic's own pixel
    # size, read-only, 0 with no bitmap set. Real scripts read them to
    # position something relative to a sprite without tracking its bitmap
    # dimensions separately -- a real VX Ace release's own bundled
    # speech-bubble add-on centres its tail sprite this way
    # (`self.y - @tail.height / 2`).
    def width
      bitmap ? bitmap.width : 0
    end

    def height
      bitmap ? bitmap.height : 0
    end

    # The viewport the sprite was created in (the native #initialize stores it to
    # keep it alive). RPG::Sprite reads it to put its damage pop-up and animation
    # cells in the same viewport as the battler — RGSS exposes it, and without the
    # reader those sprites would land on the default screen viewport instead.
    attr_reader :viewport

    # Position. Native `x=`/`y=`/`z=` store these ivars, but nothing sets them
    # before the first assignment, so the readers have to answer RGSS's default of
    # 0 rather than nil: a sprite's `x` is read *before* it is written on every
    # relative move (`RPG::Sprite#x=` computes the shift to carry its animation
    # cells along, `RPG::Weather#update` scrolls each drop from where it is), and
    # nil would raise there.
    def x
      @x || 0
    end

    def y
      @y || 0
    end

    def z
      @z || 0
    end

    # RGSS Sprite properties the stock scripts set — opacity fades, zoom, angle,
    # tone/colour, scroll origin, mirror, bush depth, blend mode, source rect,
    # flash. `opacity=`, `zoom_x=`, `zoom_y=`, `angle=`, `mirror=`, `tone=`,
    # `color=`, `src_rect=`, `blend_type=`, `bush_depth=` and `flash` are all now
    # honoured natively (src/lib.cxx sets the sprite canvas's LVGL object opacity /
    # image scale / image rotation / blend mode; mirror, tone, colour, the src_rect
    # crop, the bush-depth bottom fade and the timed flash pulse are baked into a
    # scratch copy the canvas points at, and `update` re-composites so per-frame
    # `src_rect.set` shows and an active flash decays). `bush_depth=` and `flash`
    # are native methods, so they must NOT be redefined by an `attr_writer` here —
    # that would shadow them. Only `ox`/`oy` (read by the native tone/flash pass
    # but not otherwise wired) stay Ruby-side. The readers below fall back to
    # RGSS's defaults because the native #initialize does not set these ivars (and
    # cannot be wrapped from here without replacing it). `nil?` checks — not `||` —
    # where 0/false is a meaningful value (opacity 0 = transparent).
    attr_writer :ox, :oy

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def ox
      @ox || 0
    end

    def oy
      @oy || 0
    end

    def zoom_x
      @zoom_x.nil? ? 1.0 : @zoom_x
    end

    def zoom_y
      @zoom_y.nil? ? 1.0 : @zoom_y
    end

    def angle
      @angle || 0
    end

    def mirror
      @mirror || false
    end

    def bush_depth
      @bush_depth || 0
    end

    def blend_type
      @blend_type || 0
    end

    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    def color
      @color ||= Color.new(0, 0, 0, 0)
    end

    def src_rect
      @src_rect ||= Rect.new(0, 0, 0, 0)
    end
  end

  # RGSS Tilemap: the layered, autotiled map ground Spriteset_Map builds from the
  # tileset, the seven autotiles, and the map's data/priority Tables. Now native
  # (src/lib.cxx): Tilemap.new builds an lv_canvas the size of the viewport and
  # tilemap_refresh draws the visible tiles of the three map_data layers scrolled
  # by ox/oy — regular tiles from the tileset and autotiles assembled from their
  # four quads (the seven `autotiles` bitmaps are read by the native renderer).
  # `initialize`, `tileset=`, `map_data=`, `priorities=`, `ox=`/`oy=`, `z=`,
  # `update`, `visible`/`visible=`, `dispose`/`disposed?` are native. `update`
  # advances the autotile animation (frames cycle through the wider autotile
  # bitmaps). `priorities=` routes priority >= 1 tiles to a separate "above" layer
  # that sorts over the characters (an interim flat approximation of RMXP's
  # per-row priority — see docs/adr/0022-rpgxp-tilemap-priority-layering.md). This
  # reopening keeps the plain readers, the `autotiles` slot array (which the
  # native renderer reads), and `flash_data` — still stored-only — so scripts run.
  class Tilemap
    attr_reader :tileset, :map_data, :ox, :oy, :viewport, :priorities
    attr_accessor :flash_data

    # RGSS exposes exactly seven autotile slots (0..6); the game assigns each with
    # `tilemap.autotiles[i] = bitmap` and reads them back to dispose. A fixed-size
    # Array holds the references (there is no `autotiles=` in RGSS).
    def autotiles
      @autotiles ||= Array.new(7)
    end

    # RGSS2/RGSS3 (VX, VX Ace) replace the tileset + autotiles with nine sheets
    # (`bitmaps`, native) and the tileset `flags` table. A tilemap that has been
    # given any sheet is drawn the VX way; `flags=` is native (it re-tiles), so
    # this only adds the reader.
    attr_reader :flags
  end

  # RGSS Window: the framed, scrollable box every Window_Base subclass (message,
  # command, menu, shop, battle status) builds on. Now native (src/lib.cxx):
  # Window.new builds an lv_canvas the size of the window and blits the game's
  # `contents` Bitmap into the content area (inset 16px, scrolled by ox/oy) at
  # contents_opacity, and — when a `windowskin` is set — draws the stretched
  # background at `back_opacity`, the 9-slice frame at `opacity`, the blinking
  # cursor highlight at `cursor_rect` (when `active`) and the pause arrow (when
  # `pause`). `update` advances the blink/pause animation and redraws. Almost the
  # whole surface is native — `initialize`, `contents=`, `windowskin=`, `x=`,
  # `y=`, `width=`, `height=`, `ox=`, `oy=`, `opacity=`, `back_opacity=`,
  # `contents_opacity=`, `cursor_rect=`, `active=`, `pause=`, `stretch=`,
  # `update`, `z=`, `visible`/`visible=`, `dispose`/`disposed?`. `stretch=` picks
  # between the stretched (default) and tiled windowskin background. This reopening
  # only adds the plain readers and their RGSS defaults.
  class Window
    attr_reader :contents, :windowskin, :x, :y, :width, :height, :ox, :oy, :z,
                :viewport, :contents_opacity

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def back_opacity
      @back_opacity.nil? ? 255 : @back_opacity
    end

    def cursor_rect
      @cursor_rect ||= Rect.new(0, 0, 0, 0)
    end

    def active
      @active.nil? ? true : @active
    end

    def pause
      @pause || false
    end

    def stretch
      @stretch.nil? ? true : @stretch
    end

    # ---- RGSS2 / RGSS3 (VX, VX Ace) additions ------------------------------
    #
    # The VX and VX Ace window model adds an open/close animation and a content
    # padding the scripts drive themselves: `Window_Base#open`/`#close` step
    # `openness` by 48 a frame and wait on `open?`/`close?`, and every VX window
    # lays its contents out relative to `padding`. Measured in the stock VX Ace
    # scripts: openness x16, open?/close? x15, padding x8, arrows_visible x1 (see
    # docs/rpgvx-rgss-api-gap.md).
    #
    # `openness=` and `tone`/`tone=` are native (src/lib.cxx): both have to
    # redraw, since the frame is drawn at a fraction of its height to animate the
    # open/close and the tone tints the background. They must NOT be defined here
    # — mrblib loads after the C init and would shadow them. `padding` and the
    # rest below really are plain state the scripts drive.

    # 0 (fully closed) .. 255 (fully open).
    def openness
      @openness.nil? ? 255 : @openness
    end

    def open?
      openness == 255
    end

    def close?
      openness.zero?
    end

    # The margin between the window frame and its contents. RGSS3's default is
    # 12; the native drawing still insets contents by its own border, so this is
    # the value the scripts compute layouts with.
    def padding
      @padding.nil? ? 12 : @padding
    end

    attr_writer :padding

    def padding_bottom
      @padding_bottom.nil? ? padding : @padding_bottom
    end

    attr_writer :padding_bottom

    # Whether the scroll arrows are drawn on a window whose contents overflow.
    def arrows_visible
      @arrows_visible.nil? ? true : @arrows_visible
    end

    attr_writer :arrows_visible

    # RGSS2/RGSS3 construct a window with its geometry — `Window.new(x, y,
    # width, height)` — where RGSS1 (XP) took an optional viewport and had the
    # geometry assigned afterwards. Every VX/VX Ace window does the former
    # (`Window_Base#initialize` calls `super(x, y, width, height)`), so accept
    # both forms: four numbers are the VX shape, anything else goes to the
    # native initializer unchanged.
    alias_method :_rgss1_initialize, :initialize

    def initialize(x = nil, y = nil, width = nil, height = nil)
      if x.is_a?(Integer) && y.is_a?(Integer)
        _rgss1_initialize
        self.x = x
        self.y = y
        self.width = width.to_i
        self.height = height.to_i
      elsif x.nil?
        _rgss1_initialize
      else
        _rgss1_initialize(x)
      end
    end
  end

  # RGSS Viewport. Native (src/lib.cxx): the clipping frame, its scrolled
  # content layer, `rect`/`ox`/`oy`/`z`/`visible`, and — for the RGSS2/RGSS3
  # screen effects — `color`/`color=` and `flash`, drawn as a colour overlay
  # above the viewport's contents and refreshed from `update`. This reopening
  # only adds the tone.
  class Viewport
    # `tone`/`tone=` are native now too (src/lib.cxx). Unlike `color` — one more
    # layer over the viewport's contents — a tone *rescales what is drawn*
    # (desaturate toward luminance, then offset each channel), so it cannot be an
    # overlay: every display object in the viewport folds the tone into its own
    # composite, and the viewport re-composites them when the value changes
    # (including the in-place `viewport.tone.set(...)` the scripts use, which
    # #update re-reads each frame). Nothing to add here.
  end

  class RGSSError < StandardError
  end

  # RGSS Audio module. The public methods resolve a game-supplied name to a real
  # file (mirroring how Bitmap searches GAME_DIR/RTP_DIR) and hand it to the
  # native SDL_mixer backend defined in src/audio.cxx + src/sdl_audio.cxx. When
  # no backend is installed (the standalone test build, or a build/host without
  # an audio device) the native primitives are graceful no-ops.
  module Audio
    # Sub-folders searched for each kind of audio, relative to GAME_DIR/RTP_DIR.
    # "" lets a name that already carries its folder (or an absolute path)
    # resolve as given. RPG2000 keeps music under Music/ and effects under
    # Sound/; the Audio/* folders cover RPG Maker XP-style layouts.
    MUSIC_DIRS = ["", "Music", "Audio/BGM", "Audio/BGS", "Audio/ME"].freeze
    SOUND_DIRS = ["", "Sound", "Audio/SE"].freeze
    # Tried in order after the name as-is; the data usually omits the extension.
    EXTS = ["", ".ogg", ".wav", ".mid", ".midi", ".mp3", ".flac"].freeze
    # Every spelling of those to actually try: each one, then its upper-case
    # form. RPG Maker games were authored on Windows, whose filesystem does not
    # distinguish the two, so a released game mixes them freely inside a single
    # folder -- Pray for You's Audio/BGM holds ten `.MID` beside eight `.mid`,
    # and on a case-sensitive filesystem the upper-case ten resolved to nothing
    # ("Audio: no BGM found for ..." on a file that is right there).
    EXT_SPELLINGS = begin
      list = []
      EXTS.each do |e|
        list << e
        up = e.upcase
        list << up unless up == e
      end
      list.freeze
    end

    # The archive sub-folders each kind of audio lives in, for a packed release.
    # Unlike the disk search these are exact: an archive entry name is whatever
    # the editor wrote, and RGSS2/RGSS3 projects keep the four kinds apart.
    # Ordered so the usual home of each kind is tried first.
    ARCHIVE_DIRS = {
      bgm: ["Audio/BGM", "Audio/ME", "Audio/BGS", "Music", ""],
      bgs: ["Audio/BGS", "Audio/BGM", "Music", ""],
      me: ["Audio/ME", "Audio/BGM", "Music", ""],
      se: ["Audio/SE", "Sound", ""]
    }.freeze

    class << self
      # `pos` is RGSS3-only (VX Ace added it over XP/VX's 3-argument form) --
      # real scripts pass it to resume a BGM from where a prior track left
      # off (RPG::BGM#replay, a bare `Audio.bgm_play(f, v, p, pos)` in a
      # volume-control add-on). Milliseconds, the same unit #bgm_pos reports
      # in, so `Audio.bgm_play(f, v, p, Audio.bgm_pos)` round-trips exactly --
      # a real VX Ace script's own hardcoded literal may use a different
      # native unit (unconfirmed; SDL_mixer's own seek call takes seconds, and
      # secondary sources disagree on RGSS3's), so a value from anywhere other
      # than this engine's own #bgm_pos is not guaranteed to land on the same
      # instant a real game would land on. Seeking can still fail (some
      # decoders, e.g. MOD/MIDI, do not support it); a failed seek plays from
      # the track's own beginning rather than not playing at all.
      def bgm_play(filename, volume = 100, pitch = 100, pos = 0)
        path = resolve(filename, MUSIC_DIRS)
        return _bgm_play(path, volume, pitch, pos) if path
        play_packed(:bgm, filename, volume, pitch, pos)
      end

      # Re-applies volume to the already-playing BGM stream in place, with no
      # restart -- unlike #bgm_play, which always starts its track over.
      def bgm_volume(volume)
        _bgm_volume(volume)
      end

      # Re-applies stereo balance to the already-playing BGM stream in place,
      # with no restart -- the same live-update shape as #bgm_volume. Matches
      # RPG2000's own Play BGM balance parameter: 0 is full left, 100 is full
      # right, 50 (the default) is centre.
      def bgm_pan(pan)
        _bgm_pan(pan)
      end

      def bgm_stop
        _bgm_stop
      end

      def bgm_fade(time)
        _bgm_fade(time)
      end

      def bgm_pos
        _bgm_pos
      end

      # `pos` mirrors #bgm_play's 4th argument -- RGSS3's stock RPG::BGS#play
      # passes it the same way RPG::BGM#play does -- but BGS has no seekable
      # backend to honour it with (see #play_packed's own comment: its
      # sample-channel playback never reports a position to resume from), so
      # it is accepted and, if actually nonzero, warned about once rather
      # than raising ArgumentError on every game that calls #play this way.
      def bgs_play(filename, volume = 100, pitch = 100, pos = 0)
        RGSS.warn_once("Audio.bgs_play: pos is not supported; ignoring") if pos != 0
        path = resolve(filename, MUSIC_DIRS)
        return _bgs_play(path, volume, pitch) if path
        play_packed(:bgs, filename, volume, pitch)
      end

      def bgs_stop
        _bgs_stop
      end

      def bgs_fade(time)
        _bgs_fade(time)
      end

      def bgs_pos
        _bgs_pos
      end

      def me_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, MUSIC_DIRS)
        return _me_play(path, volume, pitch) if path
        play_packed(:me, filename, volume, pitch)
      end

      def me_stop
        _me_stop
      end

      def me_fade(time)
        _me_fade(time)
      end

      def se_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, SOUND_DIRS)
        return _se_play(path, volume, pitch) if path
        play_packed(:se, filename, volume, pitch)
      end

      def se_stop
        _se_stop
      end

      # True when a MIDI patch set was resolved, i.e. when a .mid BGM/ME will be
      # audible rather than silent. False in builds with no audio backend (the
      # `rake test` binary) and when no TiMidity configuration was found.
      def midi_available?
        _midi_available
      end

      # RGSS2+. The VX/VX Ace scripts call it once at boot when the project asks
      # for MIDI playback. The synth is configured when the audio device opens
      # (src/sdl_audio.cxx picks up assets/timidity, or TIMIDITY_CFG), so there
      # is nothing left to do here; warn only when MIDI would be silent.
      def setup_midi
        unless midi_available?
          RGSS.warn_once("Audio.setup_midi: no MIDI patch set; MIDI will be silent")
        end
        nil
      end

      private

      # Play +filename+ out of the game's encrypted archive, if one is
      # registered (see RGSS.asset_archive). A released game packs its whole
      # Audio/ tree in there with nothing loose, so this is the only route to
      # its music; it runs after the disk search misses, so loose files still
      # shadow packed ones as in RGSS.
      #
      # Returns nil either way — RGSS's Audio.*_play has no return value, and a
      # miss here is the same "asset not found" silence the disk path gives.
      #
      # `pos` is BGM's own mid-track resume position (see #bgm_play); every
      # other kind ignores it. It has to be threaded through here too, not
      # just the disk path in #bgm_play, because a released game's whole
      # Audio/ tree is packed into one encrypted archive with nothing loose on
      # disk (see RGSS.asset_archive) -- this is the path that actually
      # carries a resume for a released game.
      def play_packed(kind, filename, volume, pitch, pos = 0)
        return nil if filename.nil? || filename.empty?
        archive = RGSS.asset_archive
        name, bytes = archive ? find_packed(archive, kind, filename) : nil
        if bytes.nil?
          # Neither a real file (the caller already searched GAME_DIR/RTP_DIR
          # and every known extension) nor an archive entry. Say so once: an
          # unresolved name is otherwise a silent no-op, which sounds exactly
          # like a broken decoder and sent us looking in the wrong place.
          RGSS.warn_once(
            "Audio: no #{kind.to_s.upcase} found for #{filename.inspect}")
          return nil
        end
        # Say so once rather than dropping every play silently: on a build with
        # no audio backend (or one predating the memory entry points) a packed
        # game would otherwise be mysteriously mute.
        unless _can_play_mem?
          RGSS.warn_stub("Audio: playing from an encrypted archive")
          return nil
        end
        case kind
        when :bgm then _bgm_play_mem(name, bytes, volume, pitch, pos)
        when :bgs then _bgs_play_mem(name, bytes, volume, pitch)
        when :me then _me_play_mem(name, bytes, volume, pitch)
        else _se_play_mem(name, bytes, volume, pitch)
        end
        nil
      end

      # The first archive entry matching +filename+ for +kind+, as
      # [entry name, bytes], or nil. Crosses the kind's folders with the same
      # extensions the disk search uses, because the data usually names a track
      # without either.
      def find_packed(archive, kind, filename)
        ARCHIVE_DIRS[kind].each do |dir|
          base = dir.empty? ? filename : "#{dir}/#{filename}"
          EXT_SPELLINGS.each do |ext|
            cand = "#{base}#{ext}"
            bytes = archive.read(cand)
            return [cand, bytes] if bytes
          end
        end
        nil
      rescue StandardError => e
        # A broken archive must not take down a play call; report and stay quiet.
        $stderr.puts "[RGSS] archive read failed for #{filename}: #{e.message}"
        nil
      end

      # First existing file for +filename+ under any (root, dir, extension)
      # combination, or nil. The name is first tried as given (an absolute path
      # or one relative to the current directory), then under GAME_DIR and
      # RTP_DIR crossed with +dirs+; an accented name stored decomposed on disk
      # is retried in NFD form, as Bitmap does.
      # Timed as `audio.resolve`: every Play SE/BGM/BGS/ME goes through here,
      # and a miss walks two roots x the kind's directories x EXT_SPELLINGS
      # (each also in its NFD spelling), so the cost is a burst of File.file?
      # syscalls on the game-loop thread rather than anything audio-related.
      def resolve(filename, dirs)
        RGSS::Profiler.section("audio.resolve") { search_for(filename, dirs) }
      end

      def search_for(filename, dirs)
        return nil if filename.nil? || filename.empty?
        found = exist_with_ext(filename)
        return found if found
        [GAME_DIR, RTP_DIR].each do |root|
          next if root.nil? || root.empty?
          dirs.each do |dir|
            base = dir.empty? ? "#{root}/#{filename}" : "#{root}/#{dir}/#{filename}"
            found = exist_with_ext(base)
            return found if found
          end
        end
        nil
      end

      # First of +base+ with each known extension appended that exists on disk
      # as a *file* (also trying the decomposed NFD form), or nil.
      #
      # File.file?, not File.exist?: EXT_SPELLINGS leads with the empty
      # extension and MUSIC_DIRS/SOUND_DIRS lead with the empty folder, so the
      # very first candidate for a track named "title" is the bare
      # `#{GAME_DIR}/title` -- and a game's asset folders sit right there.
      # Nepheshel keeps its title-screen graphics in `Title/` beside its
      # `Music/title.mid`, and on a case-insensitive filesystem (macOS, Windows)
      # that directory answered File.exist? first. The search stopped on it and
      # handed a directory to Mix_LoadMUS, which of course could not open it:
      # "Audio: failed to load music '.../title'" on a game whose MIDI is right
      # there in Music/. A directory is never a playable asset, so skip it and
      # keep looking.
      def exist_with_ext(base)
        EXT_SPELLINGS.each do |ext|
          cand = "#{base}#{ext}"
          return cand if File.file?(cand)
          nfd = RGSS.to_nfd(cand)
          return nfd if nfd != cand && File.file?(nfd)
        end
        nil
      end
    end
  end

  module Graphics
    @frame_count = 0
    @frame_rate = 40
    # The game screen, in pixels. RGSS2 added Graphics.width/height, and the
    # stock VX Ace scripts lean on them heavily (measured: width x50, height
    # x32) for camera and window-layout maths, so a boot shell declares its
    # resolution here with resize_screen — the VX/VX Ace one does (544x416,
    # matching the window src/main.cxx opens). RGSS1 has no such method, so the
    # XP resolution is the default and the XP/RPG2000 shells leave it alone.
    @width = 640
    @height = 480
    @brightness = 255
    # The frozen screen a transition dissolves away sits above every game
    # object; RGSS z values are ordinary integers, so pick one past anything a
    # game would set.
    TRANSITION_Z = 0x40000000
    # The brightness fade overlay sits just under the transition's own
    # full-screen sprite (above every game object either way; #transition
    # forces brightness back to 255 before it runs, so in practice the two
    # never need to be visible at once).
    BRIGHTNESS_Z = TRANSITION_Z - 1

    class << self
      attr_accessor :frame_count, :frame_rate
      attr_reader :width, :height, :brightness

      # RGSS2+. Also what the boot shells call to declare the screen size.
      def resize_screen(width, height)
        @width = width
        @height = height
      end

      # Run `duration` frames. Real behaviour, not a stub: the scripts use it to
      # hold a scene (fade-ins, message waits), and each update is a real frame.
      def wait(duration)
        duration.to_i.times { update }
      end

      # 0 (black) .. 255 (normal). Drawn as a full-screen black overlay above
      # every game object (see #brightness_sprite) whose opacity is
      # `255 - value` — the same technique #transition already uses for its
      # own full-screen dissolve, just a plain fade instead of a shaped one.
      def brightness=(value)
        value = 0 if value < 0
        value = 255 if value > 255
        @brightness = value
        if value >= 255
          brightness_sprite.opacity = 0 if @brightness_sprite
        else
          brightness_sprite.opacity = 255 - value
        end
      end

      # RGSS2+ fades: step brightness from its current value to the target (0
      # for fadeout, 255 for fadein) over `duration` frames, one Graphics.update
      # per step — not run the frames first and jump to the end value, which
      # would hold the screen at its *starting* brightness for the whole fade
      # and only change it on the last frame. `duration <= 0` jumps straight to
      # the target with no frame pumped, same as RGSS's own instant case.
      def fadeout(duration)
        start = @brightness
        if duration <= 0
          self.brightness = 0
          return
        end
        duration.times do |i|
          self.brightness = start - (start * (i + 1) / duration)
          update
        end
      end

      def fadein(duration)
        start = @brightness
        if duration <= 0
          self.brightness = 255
          return
        end
        diff = 255 - start
        duration.times do |i|
          self.brightness = start + (diff * (i + 1) / duration)
          update
        end
      end

      # RGSS's scene change: `freeze` grabs the current screen and `transition`
      # dissolves it away over `duration` frames, so the next scene builds itself
      # behind a still of the last one. Both are real now, on the native
      # snap_to_bitmap: freeze keeps the snapshot, and transition shows it on a
      # full-screen sprite above everything (z at the maximum) whose opacity is
      # stepped to zero — which is exactly RGSS's default fade.
      #
      # Given a `filename`, the still dissolves in the *shape* of that transition
      # graphic instead: its brightness says when each pixel gives way, and
      # `vague` how soft the boundary is. That is what makes RMXP's default
      # battle transition a pentagram rather than a fade, and it is the form a
      # released game reaches for (Pray for You opens with one). The pixel work
      # is Bitmap#_transition_alpha; a graphic that will not load, or a snapshot
      # with no alpha channel to dissolve, falls back to the plain fade.
      def freeze
        # nil when the backend cannot snapshot (it says so itself, once);
        # transition copes by falling back to a plain wait.
        @frozen = snap_to_bitmap
        nil
      end

      def transition(duration = 8, filename = nil, vague = 40)
        frozen = @frozen
        @frozen = nil
        # Through the setter, not a raw ivar write: a scene change always
        # starts from full brightness, and the brightness overlay (if a
        # previous fadeout left it visible) has to be hidden again too.
        self.brightness = 255
        return wait(duration) if frozen.nil? || duration <= 0

        map = _transition_map(filename)
        sprite = Sprite.new
        sprite.bitmap = frozen
        sprite.z = TRANSITION_Z
        # `vague` is on the transition graphic's own 0..255 brightness scale.
        softness = (vague.nil? ? 0 : vague) / 255.0
        duration.times do |i|
          if map
            # One refusal is enough: a snapshot that cannot carry the dissolve
            # will not start carrying it on a later frame, so drop the map and
            # let the rest of the run fade.
            unless frozen._transition_alpha(map, (i + 1).to_f / duration, softness)
              map.dispose
              map = nil
            end
          end
          sprite.opacity = 255 - (255 * (i + 1) / duration) if map.nil?
          update
        end
        map.dispose if map
        sprite.dispose
        frozen.dispose
        nil
      end

      # The transition graphic, or nil to fade. RGSS is handed a project-relative
      # path ("Graphics/Transitions/" + name, which is what the stock scenes
      # build), so Bitmap's own search — loose file, RTP, then the encrypted
      # archive — is the right resolver. A graphic that is not there must not end
      # a scene change, so the failure is reported once and the fade stands in.
      def _transition_map(filename)
        return nil if filename.nil? || filename.empty?
        Bitmap.new(filename)
      rescue Bitmap::LoadError => e
        RGSS.warn_once("Graphics.transition: #{filename} did not load " \
                       "(#{e.reason}); fading instead")
        nil
      rescue StandardError => e
        RGSS.warn_once("Graphics.transition: #{filename} did not load " \
                       "(#{e.message}); fading instead")
        nil
      end

      private

      # The full-screen black sprite #brightness= fades in and out of view,
      # created once and kept alive at BRIGHTNESS_Z (opacity 0, i.e.
      # invisible, whenever brightness is 255) rather than allocated fresh on
      # every fade -- a game commonly fades in and out many times a session
      # (every battle, every map transfer). Recreated if the screen size
      # changes out from under it (#resize_screen is normally called once at
      # boot, before any fade, but nothing stops a script calling it again).
      def brightness_sprite
        if @brightness_sprite && @brightness_sprite.bitmap &&
           @brightness_sprite.bitmap.width == width &&
           @brightness_sprite.bitmap.height == height
          return @brightness_sprite
        end
        @brightness_sprite.dispose if @brightness_sprite
        bmp = Bitmap.new(width, height)
        bmp.fill_rect(0, 0, width, height, Color.new(0, 0, 0, 255))
        @brightness_sprite = Sprite.new
        @brightness_sprite.bitmap = bmp
        @brightness_sprite.z = BRIGHTNESS_Z
        @brightness_sprite.opacity = 0
        @brightness_sprite
      end
    end
  end

  module Input
    # Key constants
    UP = 0
    DOWN = 1
    LEFT = 2
    RIGHT = 3
    A = 4
    B = 5
    C = 6
    X = 7
    Y = 8
    Z = 9
    L = 10
    R = 11
    SHIFT = 12
    CTRL = 13
    ALT = 14
    F5 = 15
    F6 = 16
    F7 = 17
    F8 = 18
    F9 = 19
    F12 = 20

    # RPG2003's Key Input Processing event command can accept a numeric
    # keypad (Numbers) or math-operator (Operators) group instead of the
    # console/keyboard button set above (Game::Interpreter#do_key_input,
    # Scene::Map::NUMBER_KEY_BUTTONS / OPERATOR_KEY_BUTTONS). Ids continue the
    # F12 sequence; the digit/operator identity (not the id) is what matters,
    # since Scene::Map re-maps each hit onto the RPG2000 key-input code
    # (Game::Interpreter::KEY_INPUT_CODES). Key backing: the SDL desktop backend
    # (src/sdl_input.cxx) binds every digit and operator; the terminal/sixel
    # backends now type them too (mruby-rgss/src/terminal.cxx), since a keyboard
    # can actually produce them; the PSP backend binds the first five digits
    # (N0-N4) to its spare buttons (Square/L/R/Start/Select,
    # include/psp.hxx + mruby-rgss/src/psp.cxx); the Wio Terminal has no free
    # pin (its seven buttons are all assigned), so these ids stay unbound there,
    # the same way it already leaves F5-F12 unbound.
    N0 = 21
    N1 = 22
    N2 = 23
    N3 = 24
    N4 = 25
    N5 = 26
    N6 = 27
    N7 = 28
    N8 = 29
    N9 = 30
    PLUS = 31
    MINUS = 32
    MULTIPLY = 33
    DIVIDE = 34
    PERIOD = 35

    # RGSS2 (VX) and RGSS3 (VX Ace) name the keys with **symbols** —
    # `Input.trigger?(:C)` — where RGSS1 (XP) used the integer constants above.
    # The stock VX Ace scripts use symbols exclusively (measured: :C, :UP/:DOWN/
    # :LEFT/:RIGHT, :B, :A, :L, :R, :CTRL, :F9 — see docs/rpgvx-rgss-api-gap.md),
    # so map them onto the same key indices instead of keeping two key tables.
    # An Integer is passed through untouched, so every XP / RPG2000 caller and
    # the C++ input bridge are unaffected. N0-N9/PLUS-PERIOD have no RGSS
    # precedent (RPG2003's own Numbers/Operators keys, not an RGSS button) but
    # are listed the same way for a consistent `Input.trigger?(:N3)` spelling.
    SYMBOL_KEYS = {
      UP: UP, DOWN: DOWN, LEFT: LEFT, RIGHT: RIGHT,
      A: A, B: B, C: C, X: X, Y: Y, Z: Z, L: L, R: R,
      SHIFT: SHIFT, CTRL: CTRL, ALT: ALT,
      F5: F5, F6: F6, F7: F7, F8: F8, F9: F9, F12: F12,
      N0: N0, N1: N1, N2: N2, N3: N3, N4: N4,
      N5: N5, N6: N6, N7: N7, N8: N8, N9: N9,
      PLUS: PLUS, MINUS: MINUS, MULTIPLY: MULTIPLY, DIVIDE: DIVIDE, PERIOD: PERIOD
    }.freeze

    @pressed = Array.new(36, false)
    @triggered = Array.new(36, false)
    @repeated = Array.new(36, false)
    @count = Array.new(36, 0)

    # Key index for either spelling. An unrecognised key reads as unpressed
    # rather than raising (a script may probe a key this build has no name for),
    # but it is reported once so the omission is visible in the log.
    def self.key_index(key)
      return key if key.is_a?(Integer)
      index = SYMBOL_KEYS[key]
      RGSS.warn_stub("Input key #{key.inspect}") if index.nil?
      index
    end

    # RGSS's contract: "updates input data — as a rule, call once per frame",
    # and every key a game reads afterwards reflects what this call sampled. So
    # this is where the backends' buffered transitions are applied (`_poll`,
    # native: the SDL window backend via src/sdl_input.cxx, the terminal
    # backends, wio/psp), *after* the previous frame's triggers expire and
    # *before* the repeat bookkeeping runs over the new state.
    #
    # The order is what makes a game's own engine playable. An RGSS scene loop is
    #
    #   loop { Graphics.update; Input.update; update; break if $scene != self }
    #
    # so while the drain lived in Graphics.update, every transition it applied
    # was wiped by the game's own Input.update on the very next line, before the
    # scene read it: `Input.trigger?` was permanently false under the script host
    # and no bundled game could be played. The built-in RPG2000/XP flows and the
    # MV/MZ bridges all call Input.update once a frame as well, so their timing
    # is unchanged (they read the state on the following frame either way).
    def self.update
      # Last frame's triggers expire first: a trigger lives exactly one frame.
      @triggered.each_index do |i|
        @triggered[i] = false
      end

      # Then this frame's transitions arrive (.press / .release set pressed and
      # triggered), so a tap that landed since the last call is visible now.
      _poll

      # Update repeat state. Timings measured against the genuine RPG_RT.exe
      # (RPG Maker 2000 runtime) under wine: holding a direction key on a
      # title/menu cursor moves once immediately, then again after 24 frames
      # (~400ms @60fps), then every 4 frames (~67ms) after that.
      @pressed.each_index do |i|
        if @pressed[i]
          @count[i] += 1
          if @count[i] >= 24 && @count[i] % 4 == 0
            @repeated[i] = true
          else
            @repeated[i] = false
          end
        else
          @repeated[i] = false
          @count[i] = 0
        end
      end
    end

    def self.press(key)
      index = key_index(key)
      return if index.nil?
      @pressed[index] = true
      @triggered[index] = true
      @count[index] = 0
    end

    # A release clears the held state but deliberately leaves `triggered` alone.
    # Transitions arrive in a buffer that is drained once a frame (the SDL key
    # watch, the browser's on-screen keypad, the terminal backends), so a quick
    # tap can deliver its press *and* its release into the same drain. Clearing
    # the trigger here swallowed that tap completely -- the game saw a key that
    # was never pressed. `update` clears every trigger at the end of the frame,
    # so nothing can outlive the frame it arrived in either way.
    def self.release(key)
      index = key_index(key)
      return if index.nil?
      @pressed[index] = false
      @count[index] = 0
    end

    def self.press?(key)
      index = key_index(key)
      index.nil? ? false : @pressed[index]
    end

    def self.trigger?(key)
      index = key_index(key)
      index.nil? ? false : @triggered[index]
    end

    def self.repeat?(key)
      index = key_index(key)
      index.nil? ? false : @repeated[index]
    end

    def self.dir4
      return 2 if press?(DOWN)
      return 4 if press?(LEFT)
      return 6 if press?(RIGHT)
      return 8 if press?(UP)
      return 0
    end

    def self.dir8
      return 1 if press?(DOWN) && press?(LEFT)
      return 3 if press?(DOWN) && press?(RIGHT)
      return 7 if press?(UP) && press?(LEFT)
      return 9 if press?(UP) && press?(RIGHT)
      return dir4
    end

    # Pointer state, captured by the SDL window backend (see input_bridge.cxx).
    # In game/canvas pixels; (0, 0) and unpressed under backends with no mouse.
    # MV's TouchInput bridge reads these for menu/title clicking.
    def self.mouse_x
      RGSS.mouse_x
    end

    def self.mouse_y
      RGSS.mouse_y
    end

    def self.mouse_pressed?
      RGSS.mouse_pressed?
    end
  end
end
