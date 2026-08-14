class Object
  include RGSS
end

class RPG2k
  # RPG Maker 2000 style window. The visual is assembled from a "windowskin"
  # System graphic laid out in the classic 160x80 arrangement:
  #
  #   (0, 0, 32, 32)   background fill (stretched over the interior)
  #   (32, 0, 32, 32)  8px-thick frame border, split into 4 corners and 4 edges
  #
  # The window is a Viewport that clips its contents to the window rectangle.
  # Rather than compositing everything into one Bitmap, separate Sprites are
  # layered inside the viewport by their `z`: the windowskin (background +
  # frame), the selection cursor, the contents (text and other graphics drawn
  # by callers), and the blinking "waiting for input" arrow. Keeping them
  # apart means updating the cursor or the text no longer forces the skin to
  # be re-blitted.
  #
  # RPG2k::Window, not RGSS::Window: this is the RPG Maker 2000 window, and the
  # RGSS one is a different widget with a different windowskin layout that a
  # real XP/VX game's own scripts subclass (`Window_Base < Window`). Defining
  # this one under RGSS used to replace that native class for the whole process,
  # since mruby-rpg2k loads after mruby-rgss -- see the note in build_config.rb.
  # Every use is inside `class RPG2k`, so the bare name still resolves here.
  class Window
    # Windows are drawn above ordinary background sprites (which default to
    # z == 0), so give the backing viewport a high z by default.
    DEFAULT_Z = 100

    # Thickness of the RPG2k frame border, in pixels.
    BORDER = 8

    # z of each layer within the window's viewport (skin at the back, text on
    # top, cursor highlight sandwiched between them, the pause arrow in front
    # of everything -- it overlays whatever contents happen to be under it).
    SKIN_Z = 0
    CURSOR_Z = 1
    CONTENTS_Z = 2
    ARROW_Z = 3

    # Geometry of the blinking "waiting for input" arrow: an 8px-tall strip
    # inside the frame block (32,0)-(64,32) of the System windowskin, blitted
    # centred at the bottom of the window. Unlike Game::WindowCursor, there is
    # no real RPG_RT frame in this repo to measure this against, so the source
    # rect and the 20-frames-on/20-frames-off blink are ported from EasyRPG
    # Player's src/window.cpp.
    ARROW_SRC_X = 40
    ARROW_SRC_Y = 16
    ARROW_W = 16
    ARROW_H = 8
    ARROW_BLINK_FRAMES = 20

    def initialize(x = 0, y = 0, width = 0, height = 0)
      @x = x
      @y = y
      @width = width
      @height = height
      @contents = nil
      @windowskin = nil
      @cursor_rect = Rect.new(0, 0, 0, 0)
      @active = true
      @visible = true
      @pause = false
      @arrow_anim = 0
      # Open/close animation: RPG_RT unrolls a window from its horizontal
      # centre line rather than popping it in, ported from EasyRPG Player's
      # Window::SetOpenAnimation/SetCloseAnimation (src/window.cpp). @openness
      # is 0.0 (closed, nothing drawn) .. 1.0 (fully open); everything but the
      # skin/frame is hidden until it reaches 1.0, matching RGSS::Window's own
      # openness draw (mruby-rgss/src/lib.cxx) -- see #open_animation below.
      @openness = 1.0
      @anim_frames_left = 0
      @anim_step = 0.0
      @anim_closing = false

      # The viewport groups and clips the four layers to the window rect.
      @viewport = Viewport.new(x, y, [width, 1].max, [height, 1].max)
      @viewport.z = DEFAULT_Z

      @skin_sprite = Sprite.new(@viewport)
      @skin_sprite.z = SKIN_Z
      @cursor_sprite = Sprite.new(@viewport)
      @cursor_sprite.z = CURSOR_Z
      # Contents are drawn inside the frame, so offset the sprite by the border.
      @contents_sprite = Sprite.new(@viewport)
      @contents_sprite.z = CONTENTS_Z
      @contents_sprite.x = BORDER
      @contents_sprite.y = BORDER
      @contents_sprite.visible = false
      @arrow_sprite = Sprite.new(@viewport)
      @arrow_sprite.z = ARROW_Z
      @arrow_sprite.visible = false
      @arrow_bmp = Bitmap.new(ARROW_W, ARROW_H)
      @arrow_sprite.bitmap = @arrow_bmp

      allocate_skin
    end

    attr_reader :x, :y, :width, :height, :contents, :windowskin, :cursor_rect
    attr_reader :active, :visible, :pause

    def x=(v)
      @x = v
      update_rect
    end

    def y=(v)
      @y = v
      update_rect
    end

    def z=(v)
      @viewport.z = v
    end

    def width=(v)
      @width = v
      allocate_skin
      update_rect
    end

    def height=(v)
      @height = v
      allocate_skin
      update_rect
    end

    def windowskin=(bmp)
      @windowskin = bmp
      draw_skin
      draw_arrow
      bmp
    end

    # Draw the window with no frame or background (RPG2000's transparent message
    # window): only the contents layer shows. Setting it redraws the skin layer.
    def transparent=(v)
      @transparent = v ? true : false
      draw_skin
      v
    end

    def contents=(bmp)
      @contents = bmp
      @contents_sprite.visible = !bmp.nil? && fully_open?
      @contents_sprite.bitmap = bmp if bmp
      bmp
    end

    def cursor_rect=(rect)
      @cursor_rect = rect
      draw_cursor
      rect
    end

    def active=(v)
      @active = v
      draw_cursor
    end

    def visible=(v)
      @visible = v
      @viewport.visible = v
    end

    # Start the window unrolling open over `frames` frames (0 opens instantly,
    # RPG_RT's own battle-message behaviour -- see EasyRPG's
    # Game_Battle::IsBattleRunning() guard on message_animation_frames). Marks
    # the window visible, same as EasyRPG's SetOpenAnimation.
    def open_animation(frames)
      @visible = true
      @viewport.visible = true
      if frames > 0
        @openness = 0.0
        @anim_frames_left = frames
        @anim_step = 1.0 / frames
        @anim_closing = false
      else
        @openness = 1.0
        @anim_frames_left = 0
      end
      redraw_for_animation
    end

    # Start the window rolling shut over `frames` frames from its current
    # openness (0 hides it instantly). Unlike #open_animation this does not
    # dispose the window itself -- the caller drives #update until #closing?
    # goes false and disposes then, so the rest of the scene keeps running
    # while the box visibly shrinks (EasyRPG's Window_Message decouples the
    # close animation from FinishMessageProcessing the same way).
    def close_animation(frames)
      if frames > 0 && @openness > 0.0
        @anim_frames_left = frames
        @anim_step = -@openness / frames
        @anim_closing = true
      else
        @openness = 0.0
        @anim_frames_left = 0
        self.visible = false
      end
      redraw_for_animation
    end

    # Mid-animation: true from #open_animation until the window reaches full
    # openness. Callers gate input/reveal progress on this the way EasyRPG's
    # Window::Update() gates on IsOpeningOrClosing().
    def opening?
      @anim_frames_left > 0 && !@anim_closing
    end

    # Mid-animation: true from #close_animation until the window reaches zero
    # openness. The caller (Scene::Map#update_closing_windows) disposes the
    # window once this turns false.
    def closing?
      @anim_frames_left > 0 && @anim_closing
    end

    # RPG2000's message-window "waiting for input" indicator: a small arrow
    # blinking at the bottom-centre of the window. Turning it on always starts
    # from a visible frame, matching RPG_RT.
    def pause=(v)
      v = v ? true : false
      return v if v == @pause
      @pause = v
      @arrow_anim = 0
      draw_arrow_visibility
      v
    end

    # Present so the game loop can drive per-frame behaviour: advances the
    # open/close animation while one is running, and the pause-arrow blink
    # while `pause` is set. The cursor highlight itself is drawn steadily
    # (RPG_RT alternates two cursor frames, but Nepheshel's own skin draws
    # both identically -- see Game::WindowCursor), so nothing else needs a
    # per-frame tick yet.
    def update
      if @anim_frames_left > 0
        @anim_frames_left -= 1
        if @anim_frames_left <= 0
          # Snap to the exact boundary on the last frame rather than trusting
          # the accumulated float sum to land on it: 1.0 / 7 added 7 times
          # comes out to 0.9999999999999999, one ULP short of 1.0, which would
          # leave #fully_open? false forever and contents/cursor/the pause
          # arrow permanently hidden behind an apparently-finished window.
          @openness = @anim_closing ? 0.0 : 1.0
          self.visible = false if @anim_closing
        else
          @openness = [[@openness + @anim_step, 0.0].max, 1.0].min
        end
        redraw_for_animation
      end
      return unless @pause
      @arrow_anim = (@arrow_anim + 1) % (ARROW_BLINK_FRAMES * 2)
      draw_arrow_visibility
    end

    def dispose
      # Dispose the layers before the viewport so each Sprite tears its own
      # LVGL object down; disposing the viewport then only frees the frame.
      [@skin_sprite, @cursor_sprite, @contents_sprite, @arrow_sprite].each(&:dispose)
      @viewport.dispose
    end

    private

    # Move/resize the viewport to track the window rectangle.
    def update_rect
      @viewport.rect = Rect.new(@x, @y, [@width, 1].max, [@height, 1].max)
    end

    # (Re)create the skin and cursor bitmaps whenever the window is resized,
    # then redraw both layers and re-centre the (fixed-size) arrow sprite.
    def allocate_skin
      @skin_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @skin_sprite.bitmap = @skin_bmp
      @cursor_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @cursor_sprite.bitmap = @cursor_bmp
      position_arrow
      draw_skin
      draw_cursor
    end

    # Re-centre the arrow sprite at the bottom of the (possibly resized)
    # window. Viewport-local coordinates, like every other layer here.
    def position_arrow
      @arrow_sprite.x = @width / 2 - ARROW_W / 2
      @arrow_sprite.y = @height - ARROW_H
    end

    # (Re)draw the arrow bitmap from the current windowskin, or a plain
    # fallback triangle when there is none to blit.
    def draw_arrow
      @arrow_bmp.clear
      if @windowskin
        @arrow_bmp.blt 0, 0, @windowskin,
                       Rect.new(ARROW_SRC_X, ARROW_SRC_Y, ARROW_W, ARROW_H)
      else
        draw_arrow_fallback
      end
    end

    # No windowskin to take the arrow art from: a small solid triangle,
    # narrowing by a pixel on each side per row.
    def draw_arrow_fallback
      color = Color.new(232, 232, 248, 255)
      ARROW_H.times do |row|
        w = ARROW_W - row * 2
        next if w <= 0
        @arrow_bmp.fill_rect row, row, w, 1, color
      end
    end

    # Show the arrow sprite only while paused, fully open and in the "on" half
    # of the blink cycle -- RPG_RT's pause arrow never shows while the window
    # is still unrolling.
    def draw_arrow_visibility
      @arrow_sprite.visible = @pause && fully_open? && @arrow_anim < ARROW_BLINK_FRAMES
    end

    def fully_open?
      @openness >= 1.0
    end

    # How tall the skin/frame band currently is, centred vertically in the
    # window rect -- the fraction of @height the animation has revealed so
    # far. Mirrors RGSS::Window's own native openness draw (`full_h *
    # openness / 255`, mruby-rgss/src/lib.cxx) so a fully-open window (the
    # default @openness of 1.0) draws exactly as before.
    def drawn_height
      return @height if fully_open?
      h = (@height * @openness).to_i
      h.negative? ? 0 : h
    end

    # Redraw the skin at the current animation frame and show/hide the layers
    # that only appear once fully open (contents, cursor, pause arrow) --
    # called from #update while an animation runs and from #open_animation /
    # #close_animation to reflect the frame the animation just jumped to.
    def redraw_for_animation
      draw_skin
      open = fully_open?
      @contents_sprite.visible = open && !@contents.nil?
      @cursor_sprite.visible = open
      draw_arrow_visibility
    end

    # Redraw the windowskin layer (background + frame, or the fallback panel),
    # clipped to the currently-animated height and centred in the window rect.
    def draw_skin
      @skin_bmp.clear
      return if @transparent # transparent message window: no frame/background
      h = drawn_height
      return if h <= 0
      y_off = (@height - h) / 2
      if @windowskin
        draw_background(y_off, h)
        draw_frame(y_off, h)
      else
        draw_fallback(y_off, h)
      end
    end

    # Stretch the 32x32 background tile over the [y_off, y_off+h) band; the
    # frame border is drawn on top of its outer edge afterwards.
    def draw_background(y_off, h)
      @skin_bmp.stretch_blt Rect.new(0, y_off, @width, h), @windowskin,
                            Rect.new(0, 0, 32, 32)
    end

    def draw_frame(y_off, h)
      w = @width
      b = BORDER
      sk = @windowskin
      # Corner height clamped to half the drawn band so a barely-open window
      # (mid open/close animation) keeps a frame instead of its top and
      # bottom corners overlapping -- same clamp RGSS::Window's native draw
      # uses. Reduces to the plain 8px corner when h >= 2 * BORDER, i.e.
      # always, for a window that is not mid-animation.
      ch = [b, h / 2].min

      # Corners (8x8 source, top/bottom-clipped to `ch` rows when shrunk).
      @skin_bmp.blt 0, y_off, sk, Rect.new(32, 0, b, ch)
      @skin_bmp.blt w - b, y_off, sk, Rect.new(56, 0, b, ch)
      @skin_bmp.blt 0, y_off + h - ch, sk, Rect.new(32, 24 + (b - ch), b, ch)
      @skin_bmp.blt w - b, y_off + h - ch, sk,
                    Rect.new(56, 24 + (b - ch), b, ch)

      # Top/bottom edges (stretched horizontally, same `ch` clip as the
      # corners they sit between).
      @skin_bmp.stretch_blt Rect.new(b, y_off, w - 2 * b, ch), sk,
                            Rect.new(40, 0, 16, ch)
      @skin_bmp.stretch_blt Rect.new(b, y_off + h - ch, w - 2 * b, ch), sk,
                            Rect.new(40, 24 + (b - ch), 16, ch)

      # Left/right edges fill whatever is left between the corners.
      mid_h = h - 2 * ch
      return unless mid_h > 0
      @skin_bmp.stretch_blt Rect.new(0, y_off + ch, b, mid_h), sk,
                            Rect.new(32, 8, b, 16)
      @skin_bmp.stretch_blt Rect.new(w - b, y_off + ch, b, mid_h), sk,
                            Rect.new(56, 8, b, 16)
    end

    # Used when no windowskin could be loaded: a plain dark panel with a light
    # border so the window is still visible.
    def draw_fallback(y_off, h)
      @skin_bmp.fill_rect 0, y_off, @width, h, Color.new(8, 8, 40, 224)
      edge = Color.new(200, 200, 216, 255)
      @skin_bmp.fill_rect 0, y_off, @width, 1, edge
      @skin_bmp.fill_rect 0, y_off + h - 1, @width, 1, edge if h > 1
      @skin_bmp.fill_rect 0, y_off, 1, h, edge
      @skin_bmp.fill_rect @width - 1, y_off, 1, h, edge
    end

    # Highlight behind the selected item, on its own layer. cursor_rect is
    # expressed in contents coordinates, so it is offset by the border
    # thickness (the contents layer carries the same offset).
    #
    # RPG2000 draws the highlight from the windowskin's own 32x32 cursor block
    # rather than as a flat bar; Game::WindowCursor holds the geometry measured
    # off a genuine RPG_RT frame. Without a windowskin there is nothing to blit,
    # so the old solid bar stays as the fallback.
    def draw_cursor
      @cursor_bmp.clear
      return unless @active
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0

      x, y, w, h =
        Game::WindowCursor.dest_rect(r.x, r.y, r.width, r.height, BORDER)
      if @windowskin
        draw_cursor_skin x, y, w, h
      else
        draw_cursor_fallback x, y, w, h
      end
    end

    # Blit the windowskin's cursor block as a 9-patch over [x, y, w, h]: 8x8
    # corners 1:1, the four edges stretched along their free axis, and the
    # centre stretched over what is left. A cursor shorter than two corners (the
    # common 16px menu row) simply has no vertical middle, so the corner strips
    # are clipped to half the height each.
    def draw_cursor_skin(x, y, w, h)
      c = Game::WindowCursor::CORNER
      sx = Game::WindowCursor::FRAME1_X
      sy = Game::WindowCursor::FRAME_Y
      sz = Game::WindowCursor::SIZE
      sk = @windowskin

      # Corner heights/widths, clipped when the destination is smaller than the
      # two corners together (then the stretched middles are empty).
      ch_top = [c, h / 2].min
      ch_bot = [c, h - ch_top].min
      cw_l = [c, w / 2].min
      cw_r = [c, w - cw_l].min
      mid_w = w - cw_l - cw_r
      mid_h = h - ch_top - ch_bot

      @cursor_bmp.blt x, y, sk, Rect.new(sx, sy, cw_l, ch_top)
      @cursor_bmp.blt x + w - cw_r, y, sk,
                      Rect.new(sx + sz - cw_r, sy, cw_r, ch_top)
      @cursor_bmp.blt x, y + h - ch_bot, sk,
                      Rect.new(sx, sy + sz - ch_bot, cw_l, ch_bot)
      @cursor_bmp.blt x + w - cw_r, y + h - ch_bot, sk,
                      Rect.new(sx + sz - cw_r, sy + sz - ch_bot, cw_r, ch_bot)

      if mid_w > 0
        @cursor_bmp.stretch_blt Rect.new(x + cw_l, y, mid_w, ch_top), sk,
                                Rect.new(sx + c, sy, sz - 2 * c, ch_top)
        @cursor_bmp.stretch_blt Rect.new(x + cw_l, y + h - ch_bot, mid_w, ch_bot),
                                sk,
                                Rect.new(sx + c, sy + sz - ch_bot, sz - 2 * c,
                                         ch_bot)
      end
      return unless mid_h > 0
      @cursor_bmp.stretch_blt Rect.new(x, y + ch_top, cw_l, mid_h), sk,
                              Rect.new(sx, sy + c, cw_l, sz - 2 * c)
      @cursor_bmp.stretch_blt Rect.new(x + w - cw_r, y + ch_top, cw_r, mid_h),
                              sk,
                              Rect.new(sx + sz - cw_r, sy + c, cw_r, sz - 2 * c)
      return unless mid_w > 0
      @cursor_bmp.stretch_blt Rect.new(x + cw_l, y + ch_top, mid_w, mid_h), sk,
                              Rect.new(sx + c, sy + c, sz - 2 * c, sz - 2 * c)
    end

    # No windowskin to take the cursor art from: a solid blue bar with a
    # brighter border, so the selection is still visible.
    def draw_cursor_fallback(x, y, w, h)
      @cursor_bmp.fill_rect x, y, w, h, Color.new(24, 40, 176, 255)
      border = Color.new(180, 200, 255, 255)
      @cursor_bmp.fill_rect x, y, w, 1, border
      @cursor_bmp.fill_rect x, y + h - 1, w, 1, border
      @cursor_bmp.fill_rect x, y, 1, h, border
      @cursor_bmp.fill_rect x + w - 1, y, 1, h, border
    end
  end

  WIDTH = 320
  HEIGHT = 240

  # RPG2000's save-select screen offers exactly 15 file slots -- the editor's
  # own Database has no setting to change it, and RPG_RT.exe hardcodes the
  # figure throughout (the file list, the Save<N>.lsd naming). Scene::SaveLoad
  # (the file-select UI) and every slot-path helper below share this constant
  # rather than repeating the literal.
  MAX_SAVE_SLOTS = 15

  attr_reader :db, :map_tree, :test_play
  # Whether the title screen's background picture and command-window position
  # should follow HideTitle (see Scene::Title). Named with a `?` since it
  # answers a question, unlike the plain `test_play` value above.
  def hide_title?; @hide_title; end

  # RPG_RT.exe (and the RPG2000/2003 editor's own Test Play button) is launched
  # with bare positional words instead of --flag=value ones, e.g.
  # `Game.exe TestPlay HideTitle Window`. None of those look like a flag, so
  # src/main.cxx's gflags parsing leaves them untouched and they arrive here as
  # ordinary constructor args instead -- this is the one place that receives
  # them, so it is the one place that has to understand them:
  #
  # - TestPlay: the editor is running the game, not a player. Recorded on
  #   `test_play` for scenes to read; nothing here changes behaviour on it yet.
  # - HideTitle: read by Scene::Title, which skips the title picture and
  #   centres the command window instead of docking it to where the picture
  #   would have been.
  # - Window: RPG_RT defaults to fullscreen and this switches it to windowed.
  #   This build's SDL backend has no fullscreen mode to begin with (see the
  #   Toggle Fullscreen event command in interpreter.rb), so the word is
  #   accepted -- it must not be treated as an unknown/invalid argument -- but
  #   there is nothing left for it to switch.
  #
  # `test_play` is also true when src/main.cxx resolved this run as test play
  # some other way -- the project's own Game.ini `[Game] Test=1`, or an
  # explicit --test_play -- since a RPG_RT.exe launched by the real editor
  # always carries the TestPlay word too; TEST_PLAY only exists when this is
  # the native binary (see scripts/rpg2k_scene_check.rb, which loads this file
  # under plain CRuby and never defines it).
  def initialize args
    @test_play = args.include?('TestPlay') || native_test_play?
    @hide_title = args.include?('HideTitle')

    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    @map_tree = LCF::MapTree.new File.open "#{GAME_DIR}/RPG_RT.lmt"
    @scenes = []
    push Scene::Title.new self
  end

  # See the TEST_PLAY comment on #initialize above.
  def native_test_play?
    TEST_PLAY
  rescue StandardError
    false
  end
  private :native_test_play?

  def push scene
    @scenes.push scene
  end

  # Pop the top scene (e.g. closing the menu), disposing it. The base scene is
  # never popped so the loop always has something to update.
  def pop
    return if @scenes.size <= 1
    scene = @scenes.pop
    scene.dispose if scene.respond_to?(:dispose)
  end

  # Pop every scene down to (and stopping at) the base `Scene::Map`, disposing
  # each in turn. Mirrors EasyRPG's `Scene::PopUntil(Scene::Map)`: casting an
  # Escape / Teleport field skill closes the whole menu stack in one step
  # rather than leaving the player to cancel out of it manually, matching
  # RPG_RT's own "warp closes the menu" behaviour.
  def pop_to_map
    pop while @scenes.size > 1
  end

  # Tear down all scenes and return to a fresh title screen.
  def return_to_title
    @scenes.each { |s| s.dispose if s.respond_to?(:dispose) }
    @scenes = [Scene::Title.new(self)]
  end

  # Tear down all scenes and show the Game Over screen; dismissing it returns to
  # the title. Replaces the stack the way return_to_title does rather than
  # pushing, so the map underneath is gone for good — the run is over.
  # `state` is the running Game::State (the map's own, when this is reached
  # through a battle/event game over); Scene::GameOver reads a Change System
  # BGM game-over override off it when one is present.
  def show_game_over(state = nil)
    @scenes.each { |s| s.dispose if s.respond_to?(:dispose) }
    @scenes = [Scene::GameOver.new(self, state)]
  end

  # Load one map (.lmu) by id. Map files are named Map0001.lmu, Map0002.lmu, ...
  def load_map id
    num = id.to_s
    num = "0#{num}" while num.size < 4
    path = "#{GAME_DIR}/Map#{num}.lmu"
    Game::Map.new id, LCF::MapUnit.new(File.open(path))
  end

  # New Game: build the initial party from the database, read the start
  # position from the map tree, load the starting map and enter the map scene.
  # The map/player renderer is not wired up yet, so this establishes the running
  # game state and transitions scenes without drawing the map.
  def start_new_game
    init = map_tree.initial
    state = Game::State.new Game::Party.new(@db), init.initial_map_id,
                            init.initial_x, init.initial_y
    # The database's System tab configures the six screen transitions a
    # "use the configured transition" (-1) Erase / Show Screen resolves against.
    state.seed_screen_transitions @db
    # The map tree's own boat/ship/airship starting positions, the editor's
    # counterpart to the hero's initial_map_id/x/y just above.
    state.seed_vehicle_positions map_tree
    state.map = load_map state.map_id
    # Build the play scene first; only tear down the title once it succeeds so a
    # data problem leaves the title intact instead of a blank screen.
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
    # A machine-readable marker so a headless run (see --rpg2k_new_game and
    # scripts/compare-nepheshel-wine.bash) can assert the map scene was really
    # reached, not just the title.
    $stderr.puts "[RPG2k-MAP] map=#{state.map_id} x=#{state.x} y=#{state.y}"
  rescue StandardError => e
    # Never let a data problem crash the title screen; report and stay put.
    $stderr.puts "[RPG2k] Failed to start new game: #{e.message}"
  end

  # Save file path for a slot. Saving still uses our own portable Marshal
  # format, but Continue can also load a genuine editor Save<N>.lsd (see
  # continue_game) via the now-modelled LCF save schema.
  def save_path slot = 1
    "#{GAME_DIR}/save#{slot}.mrb"
  end

  # Path of an editor save slot, e.g. Save01.lsd. mruby here bundles no sprintf,
  # so the two-digit slot is zero-padded by hand.
  def lsd_path slot = 1
    n = slot < 10 ? "0#{slot}" : "#{slot}"
    "#{GAME_DIR}/Save#{n}.lsd"
  end

  # Whether slot `slot` itself (not any other slot) holds a save, our own
  # Marshal `.mrb` or a genuine editor `Save<N>.lsd` either one. Scene::Title's
  # Continue used to check only slot 1 here (the only slot anything could ever
  # write to before the file-select screen existed); now that Scene::SaveLoad
  # lists all MAX_SAVE_SLOTS individually, each row asks about its own slot
  # through this same check -- see #any_save_exists? for "is there anything to
  # resume at all".
  def save_exists? slot = 1
    File.exist?(save_path(slot)) || File.exist?(lsd_path(slot))
  rescue StandardError => e
    $stderr.puts "[RPG2k] save-slot check failed for slot #{slot}: #{e.message}"
    false
  end

  # Whether *any* of the MAX_SAVE_SLOTS slots holds a save -- what gates the
  # title screen's Continue entry (Scene::Title#continue_available?). Continue
  # opens the same Scene::SaveLoad file-select list New Game's sibling Save
  # command does, so it no longer matters *which* slot has the data, only that
  # at least one does.
  def any_save_exists?
    (1..MAX_SAVE_SLOTS).any? { |slot| save_exists?(slot) }
  end

  # Persist the running game state to a slot. Our own portable Marshal dump is
  # the authoritative save (it still carries the two fields the .lsd export does
  # not model -- the game timer and per-actor name/title overrides for non-leader
  # members). Alongside it we also export a near-parity editor Save<slot>.lsd via
  # State#to_lsd, so the slot is readable by real RPG_RT/EasyRPG tooling. The
  # export is best-effort: a failure there is logged but never fails the save.
  def save_game state, slot = 1
    state.save_count += 1 # RPG2000 counts each save; persisted in the dump below
    data = Marshal.dump state.to_h
    File.open(save_path(slot), "wb") { |f| f.write data }
    export_lsd(state, slot)
    true
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to save: #{e.message}"
    false
  end

  # Write a real Save<slot>.lsd next to the Marshal save. Best-effort: any error
  # is logged and swallowed so it cannot break the primary save.
  def export_lsd state, slot = 1
    state.to_lsd(state.save_count).save_to(lsd_path(slot))
  rescue StandardError => e
    $stderr.puts "[RPG2k] .lsd export failed for slot #{slot}: #{e.message}"
  end

  # Build a Game::State from a save slot, or nil when the slot is empty. Our
  # own Marshal save is preferred when present -- it is the full-fidelity
  # record save_game wrote (save_game also exports a near-parity Save<slot>.lsd
  # beside it, which would still drop the timer and non-leader actor
  # name/title overrides if loaded instead). A genuine editor Save<N>.lsd is
  # the fallback, so a real save dropped straight into the game dir (with no
  # Marshal save) still resumes/previews through the modelled LCF save schema.
  #
  # Shared by #continue_game (which needs the one slot the player picked, or
  # slot 1 for the event-triggered Open Load Menu -- see Scene::Map
  # #perform_event_load) and Scene::SaveLoad (which builds one of these per
  # slot up front to show what each row's Continue/overwrite target actually
  # holds). Errors are logged and swallowed rather than raised: a slot a
  # caller merely wants to *preview* should degrade to "empty" rather than
  # crash the file-select screen over one unreadable file.
  def load_save_state slot = 1
    if File.exist?(save_path(slot))
      data = File.open(save_path(slot), "rb") { |f| f.read }
      Game::State.load(@db, Marshal.load(data))
    elsif File.exist?(lsd_path(slot))
      Game::State.from_lsd(@db, LCF::SaveData.new(File.open(lsd_path(slot), "rb")))
    end
  rescue StandardError => e
    $stderr.puts "[RPG2k] save slot #{slot} unreadable: #{e.message}"
    nil
  end

  # Continue: resume slot `slot`'s saved game and switch to its map. Defaults
  # to slot 1 for the event-triggered Open Load Menu (RPG2003's 5001, see
  # Scene::Map#perform_event_load), which -- unlike the title screen's own
  # Continue, routed through Scene::SaveLoad's file-select list -- targets a
  # single slot directly. Warns and stays put when the slot is empty.
  def continue_game slot = 1
    state = load_save_state(slot)
    unless state
      RGSS.warn_stub "Continue (no save data found)"
      return
    end
    state.map = load_map state.map_id
    # apply_access: false -- a resumed save already carries its own
    # save/teleport/escape access (restored by Game::State.load / .from_lsd
    # from whatever a prior Change Save/Teleport/Escape Access command left
    # it as), which re-deriving from the current map's tree here would
    # silently discard. See Scene::Map#initialize's own comment.
    scene = Scene::Map.new(self, state, apply_access: false)
    @scenes.last.dispose
    @scenes = [scene]
    # Same marker start_new_game emits, so a headless run resuming a save (see
    # --rpg2k_continue) can assert which map it landed on -- which for a save
    # comparison is the whole point: both runtimes must reach the same one.
    $stderr.puts "[RPG2k-MAP] map=#{state.map_id} x=#{state.x} y=#{state.y}"
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to continue: #{e.message}"
  end

  def main_loop
    RGSS::Profiler.frame do
      RGSS::Profiler.section("scene.update") do
        # F12 is RPG_RT's "return to title" hotkey: it works from any scene
        # (map, menu, game over, ...), not just ones that offer it as a menu
        # command, so it is checked here rather than in an individual scene.
        # Reuses the same teardown/rebuild return_to_title already does for
        # the "End Game" menu command and the Game Over screen.
        return_to_title if Input.trigger?(Input::F12)
        @scenes.last.update
      end
      RGSS::Profiler.section("input.update") { Input.update }
      Graphics.update
    end
  end

  def start
    loop do
      main_loop
    end
  rescue RGSS::Timeout
  end
end
