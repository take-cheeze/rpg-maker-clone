# The RGSS standard library — the Ruby classes RGSS104E.dll supplies to a game,
# which its script bundle does not contain.
#
# An RPG Maker XP project ships ~90 script sections and *none* of them defines
# `RPG::Cache`, `RPG::Sprite` or `RPG::Weather`: the player provides those three,
# so the editor leaves them out of every project. That is why the script host
# (script_host.rb) could not boot a game — the bundle's 24th section opens with
# `class Sprite_Character < RPG::Sprite`, and the constant did not exist:
#
#   [RGSS] script host: section "Sprite_Character" raised
#          NameError: uninitialized constant RPG::Sprite
#
# with `Spriteset_Map`, `Scene_Map` and `Main` all behind it. These are the RGSS
# equivalents of what `mruby-rgss` already supplies natively (Bitmap, Sprite,
# Viewport, Window, …) — plain Ruby in the real player too, which is why they are
# plain Ruby here, transcribed from the definitions published in the RGSS
# Reference Manual so a game's own engine sees the behaviour it was written
# against. See docs/adr/0029-rgss-script-host-by-default.md.
#
# **Deliberate deviations from the published source**, all forced by this engine
# rather than chosen:
#
#   * **Colours are re-assigned, never mutated in place.** RGSS's version does
#     `self.color.set(...)` and `self.color.alpha = ...`; here a Sprite's colour
#     is baked into a pre-composited scratch bitmap when it is *assigned*
#     (mruby-rgss), so mutating the Color object in place would change nothing on
#     screen. Every `color.set` below is `self.color = RGSS::Color.new(...)`.
#   * **`RPG::Cache` reloads a bitmap for a hue variant** instead of RGSS's
#     `@cache[path].clone`: a Bitmap here wraps a native handle, and a shallow
#     copy would give two Ruby objects one buffer to free.
#   * **A missing asset yields a blank 32x32 bitmap and a warning**, where RGSS
#     raises. A game whose RTP is not installed must not die on its first
#     graphic — the built-in flow already draws placeholders for the same reason.
#   * **Fully-qualified `RGSS::` names**, so the file also loads under the CRuby
#     harness (scripts/rpgxp_script_host_check.rb), which shims those classes.
#   * Integer conversions where RGSS relies on Ruby's implicit Float→Integer in
#     the native setters (`opacity`).
#
# Every method RGSS publishes keeps its exact name — a game's scripts call and
# override them (`dispose_damage`, `update_animation`, `animation_set_sprites`, …)
# and a custom battle system routinely reopens this class. The handful of helpers
# that are *ours* (extracted from RGSS's inline code) are prefixed `_rgss_` so
# they cannot collide with something a script defines. For the same reason this
# file is not a place to tidy: the published definitions are the specification,
# quirks included (`RPG::Weather` loops 1..40 over a 0..39 array, so a game asking
# for 40 drops gets 39 — in the real player too).

# Ruby's own `Errno`, which this mruby build does not ship (no mruby-errno gem is
# vendored or configured) and which every RGSS game needs to *exist*, whether or
# not it is ever raised. The editor writes this into the "Main" section of every
# project:
#
#   begin
#     $scene = Scene_Title.new
#     $scene.main while $scene != nil
#     Graphics.transition(20)
#   rescue Errno::ENOENT
#     print("Unable to find file #{$!.message.sub("No such file or directory - ", "")}.")
#   end
#
# A rescue clause is evaluated when an exception passes through it, so with no
# `Errno` *any* exception leaving the game loop — including the timeout a
# headless run ends on — turned into `NameError: uninitialized constant Errno`.
# That reads as "the game crashed" when the game was running fine: it is what
# scripts/rpgxp_boot_check.bash caught the first time it booted a released game
# under the host.
#
# ENOENT is the one RGSS itself raises (RPGXP::RGSSData#read_object does now, with
# the same message shape, so the handler above prints the filename it was written
# to print). The others are here so a script that rescues one resolves the
# constant rather than losing its real exception to a NameError.
# Each definition is guarded: this file is also loaded by the CRuby harnesses
# (scripts/rpgxp_script_host_check.rb), where Ruby's real Errno already exists and
# must not be redefined — the shapes match, so the guard is what keeps this a
# *fill-in* rather than a monkeypatch.
class SystemCallError < StandardError
end unless Object.const_defined?(:SystemCallError)

module Errno
  # RGSS's message is "No such file or directory - <path>", and the stock Main
  # strips that prefix to name the file — so the argument is the *path*, as in
  # CRuby, not the whole message.
  unless const_defined?(:ENOENT)
    class ENOENT < SystemCallError
      PREFIX = "No such file or directory".freeze

      def initialize(path = nil)
        super(path.nil? || path.empty? ? PREFIX : "#{PREFIX} - #{path}")
      end
    end
  end

  class EACCES < SystemCallError; end unless const_defined?(:EACCES)
  class EEXIST < SystemCallError; end unless const_defined?(:EEXIST)
  class EINVAL < SystemCallError; end unless const_defined?(:EINVAL)
  class EISDIR < SystemCallError; end unless const_defined?(:EISDIR)
end

module RPG
  # The bitmap cache. Every graphic a game loads goes through here — the scripts
  # call `RPG::Cache.character(name, hue)`, `.tile(tileset, id, hue)`,
  # `.windowskin(name)` and so on — so it is also what keeps a map from reloading
  # its charsets every frame.
  module Cache
    @cache = {}

    # A blank bitmap stands in for both an empty name (RGSS's own behaviour) and
    # an asset that will not load (ours — see the header).
    BLANK_SIZE = 32

    def self.load_bitmap(folder_name, filename, hue = 0)
      path = folder_name + filename
      bitmap = @cache[path]
      if bitmap.nil? || bitmap.disposed?
        bitmap = filename == "" ? blank : (load_file(path) || blank)
        @cache[path] = bitmap
      end
      return bitmap if hue == 0
      hued(path, filename, hue, bitmap)
    end

    def self.animation(filename, hue)
      load_bitmap("Graphics/Animations/", filename, hue)
    end

    def self.autotile(filename)
      load_bitmap("Graphics/Autotiles/", filename)
    end

    def self.battleback(filename)
      load_bitmap("Graphics/Battlebacks/", filename)
    end

    def self.battler(filename, hue)
      load_bitmap("Graphics/Battlers/", filename, hue)
    end

    def self.character(filename, hue)
      load_bitmap("Graphics/Characters/", filename, hue)
    end

    def self.fog(filename, hue)
      load_bitmap("Graphics/Fogs/", filename, hue)
    end

    def self.gameover(filename)
      load_bitmap("Graphics/Gameovers/", filename)
    end

    def self.icon(filename)
      load_bitmap("Graphics/Icons/", filename)
    end

    def self.panorama(filename, hue)
      load_bitmap("Graphics/Panoramas/", filename, hue)
    end

    def self.picture(filename)
      load_bitmap("Graphics/Pictures/", filename)
    end

    def self.tileset(filename)
      load_bitmap("Graphics/Tilesets/", filename)
    end

    def self.title(filename)
      load_bitmap("Graphics/Titles/", filename)
    end

    def self.windowskin(filename)
      load_bitmap("Graphics/Windowskins/", filename)
    end

    # One 32x32 tile cut out of the tileset, as a map event's "graphic is a tile"
    # setting needs. Tile ids start at 384, laid out 8 per row.
    def self.tile(filename, tile_id, hue)
      key = "#{filename}\t#{tile_id}\t#{hue}"
      bitmap = @cache[key]
      return bitmap unless bitmap.nil? || bitmap.disposed?
      bitmap = RGSS::Bitmap.new(32, 32)
      x = (tile_id - 384) % 8 * 32
      y = (tile_id - 384) / 8 * 32
      bitmap.blt(0, 0, tileset(filename), RGSS::Rect.new(x, y, 32, 32))
      bitmap.hue_change(hue) unless hue == 0
      @cache[key] = bitmap
    end

    # RGSS empties the cache between scenes (its `Scene_*` do this on a map
    # change) and collects. Keep the same contract; the bitmaps themselves are
    # freed by the GC with their handles.
    def self.clear
      @cache = {}
      GC.start if Object.const_defined?(:GC)
    end

    # A hue-rotated copy, cached under its own key. RGSS clones the cached bitmap
    # and rotates the clone; a native handle cannot be shallow-copied, so this
    # loads the file a second time instead. `base` is the hue-0 bitmap already in
    # the cache, returned when there is nothing to reload — an empty name, or a
    # file that did not load, where rotating the stand-in would only give the
    # caller a *differently* blank bitmap.
    def self.hued(path, filename, hue, base)
      cached = @cache["#{path}\t#{hue}"]
      return cached unless cached.nil? || cached.disposed?
      bitmap = filename == "" ? nil : load_file(path)
      return base if bitmap.nil?
      bitmap.hue_change(hue)
      @cache["#{path}\t#{hue}"] = bitmap
    end

    # Load one file, or report it and let the caller stand in. RGSS raises here;
    # a game whose RTP is missing would then die on its first graphic, so the
    # failure is reported once per path (the cache means one attempt each) and the
    # boot carries on.
    def self.load_file(path)
      RGSS::Bitmap.new(path)
    rescue StandardError => e
      $stderr.puts "[RGSS] RPG::Cache: #{path} did not load (#{e.message}); " \
                   "using a blank bitmap"
      nil
    end

    def self.blank
      RGSS::Bitmap.new(BLANK_SIZE, BLANK_SIZE)
    end
  end

  # The sprite base class every battler and character sprite in a game subclasses
  # (`Sprite_Character < RPG::Sprite`, `Sprite_Battler < RPG::Sprite`). It adds
  # the timed battle effects — whiten / appear / escape / collapse, the floating
  # damage pop-up, blinking — and plays `RPG::Animation`s over the sprite, all
  # advanced one frame at a time by #update.
  class Sprite < ::RGSS::Sprite
    # Animations whose position is "screen" (3) are drawn once no matter how many
    # targets they play on, so RGSS tracks which ones a frame has already built
    # sprites for and clears the list at the end of every #update.
    @@_animations = []
    # Animation graphics are shared between the sprites playing them; the count
    # says when the last player is done and the bitmap can go.
    @@_reference_count = {}

    def initialize(viewport = nil)
      super(viewport)
      @_whiten_duration = 0
      @_appear_duration = 0
      @_escape_duration = 0
      @_collapse_duration = 0
      @_damage_duration = 0
      @_animation_duration = 0
      @_blink = false
    end

    def dispose
      dispose_damage
      dispose_animation
      dispose_loop_animation
      super
    end

    # A weak white flash — a battler acting.
    def whiten
      self.blend_type = 0
      self.color = RGSS::Color.new(255, 255, 255, 128)
      self.opacity = 255
      @_whiten_duration = 16
      @_appear_duration = 0
      @_escape_duration = 0
      @_collapse_duration = 0
    end

    # Fade in — a revived actor, an appearing enemy.
    def appear
      self.blend_type = 0
      self.color = RGSS::Color.new(0, 0, 0, 0)
      self.opacity = 0
      @_appear_duration = 16
      @_whiten_duration = 0
      @_escape_duration = 0
      @_collapse_duration = 0
    end

    # Fade out — an enemy running away.
    def escape
      self.blend_type = 0
      self.color = RGSS::Color.new(0, 0, 0, 0)
      self.opacity = 255
      @_escape_duration = 32
      @_whiten_duration = 0
      @_appear_duration = 0
      @_collapse_duration = 0
    end

    # Red-tinted fade — a battler dying.
    def collapse
      self.blend_type = 1
      self.color = RGSS::Color.new(255, 64, 64, 255)
      self.opacity = 255
      @_collapse_duration = 48
      @_whiten_duration = 0
      @_appear_duration = 0
      @_escape_duration = 0
    end

    # The damage pop-up: white for damage, green for recovery, the text as given
    # for "Miss", with an optional CRITICAL above it. Drawn into its own bitmap
    # on a sprite at z 3000 that floats up and fades over 40 frames.
    def damage(value, critical)
      dispose_damage
      damage_string = value.is_a?(Numeric) ? value.abs.to_s : value.to_s
      bitmap = RGSS::Bitmap.new(160, 48)
      bitmap.font.name = "Arial Black"
      bitmap.font.size = 32
      bitmap.font.color = RGSS::Color.new(0, 0, 0)
      bitmap.draw_text(-1, 12 - 1, 160, 36, damage_string, 1)
      bitmap.draw_text(+1, 12 - 1, 160, 36, damage_string, 1)
      bitmap.draw_text(-1, 12 + 1, 160, 36, damage_string, 1)
      bitmap.draw_text(+1, 12 + 1, 160, 36, damage_string, 1)
      bitmap.font.color = if value.is_a?(Numeric) && value < 0
                            RGSS::Color.new(176, 255, 144)
                          else
                            RGSS::Color.new(255, 255, 255)
                          end
      bitmap.draw_text(0, 12, 160, 36, damage_string, 1)
      if critical
        bitmap.font.size = 20
        bitmap.font.color = RGSS::Color.new(0, 0, 0)
        bitmap.draw_text(-1, -1, 160, 20, "CRITICAL", 1)
        bitmap.draw_text(+1, -1, 160, 20, "CRITICAL", 1)
        bitmap.draw_text(-1, +1, 160, 20, "CRITICAL", 1)
        bitmap.draw_text(+1, +1, 160, 20, "CRITICAL", 1)
        bitmap.font.color = RGSS::Color.new(255, 255, 255)
        bitmap.draw_text(0, 0, 160, 20, "CRITICAL", 1)
      end
      @_damage_sprite = ::RGSS::Sprite.new(self.viewport)
      @_damage_sprite.bitmap = bitmap
      @_damage_sprite.ox = 80
      @_damage_sprite.oy = 20
      @_damage_sprite.x = self.x
      @_damage_sprite.y = self.y - self.oy / 2
      @_damage_sprite.z = 3000
      @_damage_duration = 40
    end

    # Play `animation` (an RPG::Animation) once over this sprite. Sixteen cell
    # sprites are built at z 2000 and re-aimed each animation frame; `hit` is what
    # the animation's SE/flash timings test.
    def animation(animation, hit)
      dispose_animation
      @_animation = animation
      return if @_animation.nil?
      @_animation_hit = hit
      @_animation_duration = @_animation.frame_max
      bitmap = Cache.animation(@_animation.animation_name,
                              @_animation.animation_hue)
      _rgss_retain(bitmap)
      @_animation_sprites = []
      if @_animation.position != 3 || !@@_animations.include?(animation)
        16.times do
          sprite = ::RGSS::Sprite.new(self.viewport)
          sprite.bitmap = bitmap
          sprite.visible = false
          @_animation_sprites.push(sprite)
        end
        @@_animations.push(animation) unless @@_animations.include?(animation)
      end
      update_animation
    end

    # The same, looping — a state animation on a battler, which runs until it is
    # replaced or cleared with nil.
    def loop_animation(animation)
      return if animation == @_loop_animation
      dispose_loop_animation
      @_loop_animation = animation
      return if @_loop_animation.nil?
      @_loop_animation_index = 0
      bitmap = Cache.animation(@_loop_animation.animation_name,
                              @_loop_animation.animation_hue)
      _rgss_retain(bitmap)
      @_loop_animation_sprites = []
      16.times do
        sprite = ::RGSS::Sprite.new(self.viewport)
        sprite.bitmap = bitmap
        sprite.visible = false
        @_loop_animation_sprites.push(sprite)
      end
      update_loop_animation
    end

    def dispose_damage
      return if @_damage_sprite.nil?
      @_damage_sprite.bitmap.dispose
      @_damage_sprite.dispose
      @_damage_sprite = nil
      @_damage_duration = 0
    end

    def dispose_animation
      return if @_animation_sprites.nil?
      _rgss_release(@_animation_sprites[0])
      @_animation_sprites.each { |sprite| sprite.dispose }
      @_animation_sprites = nil
      @_animation = nil
    end

    def dispose_loop_animation
      return if @_loop_animation_sprites.nil?
      _rgss_release(@_loop_animation_sprites[0])
      @_loop_animation_sprites.each { |sprite| sprite.dispose }
      @_loop_animation_sprites = nil
      @_loop_animation = nil
    end

    def blink_on
      return if @_blink
      @_blink = true
      @_blink_count = 0
    end

    def blink_off
      return unless @_blink
      @_blink = false
      self.color = RGSS::Color.new(0, 0, 0, 0)
    end

    def blink?
      @_blink
    end

    # True while any one-shot effect is still running. A battle scene waits on
    # this before moving on, so the durations below are what pace it. Neither the
    # looping animation nor the blink counts, by RGSS's definition.
    def effect?
      @_whiten_duration > 0 ||
        @_appear_duration > 0 ||
        @_escape_duration > 0 ||
        @_collapse_duration > 0 ||
        @_damage_duration > 0 ||
        @_animation_duration > 0
    end

    # One frame of every effect. Called from each subclass's own #update (via
    # `super`), so it runs once per game frame.
    def update
      super
      if @_whiten_duration > 0
        @_whiten_duration -= 1
        self.color = RGSS::Color.new(255, 255, 255,
                                     128 - (16 - @_whiten_duration) * 10)
      end
      if @_appear_duration > 0
        @_appear_duration -= 1
        self.opacity = (16 - @_appear_duration) * 16
      end
      if @_escape_duration > 0
        @_escape_duration -= 1
        self.opacity = 256 - (32 - @_escape_duration) * 10
      end
      if @_collapse_duration > 0
        @_collapse_duration -= 1
        self.opacity = 256 - (48 - @_collapse_duration) * 6
      end
      _rgss_update_damage if @_damage_duration > 0
      # Animations advance every other frame — RGSS's animations are 2 game
      # frames per animation frame.
      if !@_animation.nil? && (RGSS::Graphics.frame_count % 2 == 0)
        @_animation_duration -= 1
        update_animation
      end
      if !@_loop_animation.nil? && (RGSS::Graphics.frame_count % 2 == 0)
        update_loop_animation
        @_loop_animation_index += 1
        @_loop_animation_index %= @_loop_animation.frame_max
      end
      _rgss_update_blink if @_blink
      @@_animations.clear
    end

    # The pop-up's arc: up fast, up slow, back down, then fading out. Split out of
    # #update (RGSS has it inline) only to keep that method readable.
    def _rgss_update_damage
      @_damage_duration -= 1
      case @_damage_duration
      when 38, 39 then @_damage_sprite.y -= 4
      when 36, 37 then @_damage_sprite.y -= 2
      when 34, 35 then @_damage_sprite.y += 2
      when 28, 29, 30, 31, 32, 33 then @_damage_sprite.y += 4
      end
      @_damage_sprite.opacity = 256 - (12 - @_damage_duration) * 32
      dispose_damage if @_damage_duration == 0
    end

    def _rgss_update_blink
      @_blink_count = (@_blink_count + 1) % 32
      alpha = @_blink_count < 16 ? (16 - @_blink_count) * 6 : (@_blink_count - 16) * 6
      self.color = RGSS::Color.new(255, 255, 255, alpha)
    end

    def update_animation
      unless @_animation_duration > 0
        dispose_animation
        return
      end
      frame_index = @_animation.frame_max - @_animation_duration
      cell_data = @_animation.frames[frame_index].cell_data
      animation_set_sprites(@_animation_sprites, cell_data, @_animation.position)
      @_animation.timings.each do |timing|
        animation_process_timing(timing, @_animation_hit) if timing.frame == frame_index
      end
    end

    def update_loop_animation
      frame_index = @_loop_animation_index
      cell_data = @_loop_animation.frames[frame_index].cell_data
      animation_set_sprites(@_loop_animation_sprites, cell_data,
                            @_loop_animation.position)
      @_loop_animation.timings.each do |timing|
        animation_process_timing(timing, true) if timing.frame == frame_index
      end
    end

    # Aim the 16 cell sprites for one animation frame. `cell_data` is a Table of
    # [cell, field]: the 192x192 pattern index into the animation sheet, then the
    # offset, zoom, angle, mirror, opacity and blend the editor set for it.
    def animation_set_sprites(sprites, cell_data, position)
      16.times do |i|
        sprite = sprites[i]
        pattern = cell_data[i, 0]
        if sprite.nil? || pattern.nil? || pattern == -1
          sprite.visible = false unless sprite.nil?
          next
        end
        sprite.visible = true
        sprite.src_rect = RGSS::Rect.new(pattern % 5 * 192, pattern / 5 * 192,
                                         192, 192)
        if position == 3
          # "Screen": centred on the viewport, near its bottom.
          if self.viewport.nil?
            sprite.x = 320
            sprite.y = 240
          else
            sprite.x = self.viewport.rect.width / 2
            sprite.y = self.viewport.rect.height - 160
          end
        else
          sprite.x = self.x - self.ox + self.src_rect.width / 2
          sprite.y = self.y - self.oy + self.src_rect.height / 2
          sprite.y -= self.src_rect.height / 4 if position == 0   # over the target
          sprite.y += self.src_rect.height / 4 if position == 2   # under it
        end
        sprite.x += cell_data[i, 1]
        sprite.y += cell_data[i, 2]
        sprite.z = 2000
        sprite.ox = 96
        sprite.oy = 96
        sprite.zoom_x = cell_data[i, 3] / 100.0
        sprite.zoom_y = cell_data[i, 3] / 100.0
        sprite.angle = cell_data[i, 4]
        sprite.mirror = (cell_data[i, 5] == 1)
        sprite.opacity = (cell_data[i, 6] * self.opacity / 255.0).to_i
        sprite.blend_type = cell_data[i, 7]
      end
    end

    # An animation frame's SE and flash, if this frame carries one and its
    # hit/miss condition holds.
    def animation_process_timing(timing, hit)
      return unless timing.condition == 0 ||
                    (timing.condition == 1 && hit == true) ||
                    (timing.condition == 2 && hit == false)
      se = timing.se
      if !se.nil? && se.name != ""
        RGSS::Audio.se_play("Audio/SE/" + se.name, se.volume, se.pitch)
      end
      case timing.flash_scope
      when 1 then self.flash(timing.flash_color, timing.flash_duration * 2)
      when 2
        unless self.viewport.nil?
          self.viewport.flash(timing.flash_color, timing.flash_duration * 2)
        end
      when 3 then self.flash(nil, timing.flash_duration * 2)
      end
    end

    # Moving the sprite carries its animation cells along, so an animation stays
    # on a battler that is walking forward to attack.
    def x=(x)
      _rgss_shift_animation_sprites(x - self.x, 0)
      super
    end

    def y=(y)
      _rgss_shift_animation_sprites(0, y - self.y)
      super
    end

    def _rgss_shift_animation_sprites(sx, sy)
      return if sx == 0 && sy == 0
      [@_animation_sprites, @_loop_animation_sprites].each do |sprites|
        next if sprites.nil?
        sprites.each do |sprite|
          next if sprite.nil?
          sprite.x += sx unless sx == 0
          sprite.y += sy unless sy == 0
        end
      end
    end

    # Animation graphics are shared: count the players so the last one out frees
    # the bitmap.
    def _rgss_retain(bitmap)
      @@_reference_count[bitmap] = (@@_reference_count[bitmap] || 0) + 1
    end

    def _rgss_release(sprite)
      return if sprite.nil?
      bitmap = sprite.bitmap
      return if bitmap.nil?
      count = (@@_reference_count[bitmap] || 1) - 1
      @@_reference_count[bitmap] = count
      bitmap.dispose if count <= 0
    end
  end

  # Rain, storm and snow — what Change Weather Effects drives on the map. Forty
  # sprites recycled as they fall off the screen, drawn from three bitmaps the
  # class draws for itself (RGSS ships no weather graphics).
  class Weather
    SPRITE_COUNT = 40

    def initialize(viewport = nil)
      @type = 0
      @max = 0
      @ox = 0
      @oy = 0
      color1 = RGSS::Color.new(255, 255, 255, 255)
      color2 = RGSS::Color.new(255, 255, 255, 128)
      @rain_bitmap = RGSS::Bitmap.new(7, 56)
      7.times { |i| @rain_bitmap.fill_rect(6 - i, i * 8, 1, 8, color1) }
      @storm_bitmap = RGSS::Bitmap.new(34, 64)
      32.times do |i|
        @storm_bitmap.fill_rect(33 - i, i * 2, 1, 2, color2)
        @storm_bitmap.fill_rect(32 - i, i * 2, 1, 2, color1)
        @storm_bitmap.fill_rect(31 - i, i * 2, 1, 2, color2)
      end
      @snow_bitmap = RGSS::Bitmap.new(6, 6)
      @snow_bitmap.fill_rect(0, 1, 6, 4, color2)
      @snow_bitmap.fill_rect(1, 0, 4, 6, color2)
      @snow_bitmap.fill_rect(1, 2, 4, 2, color1)
      @snow_bitmap.fill_rect(2, 1, 2, 4, color1)
      @sprites = []
      SPRITE_COUNT.times do
        sprite = RGSS::Sprite.new(viewport)
        sprite.z = 1000
        sprite.visible = false
        sprite.opacity = 0
        @sprites.push(sprite)
      end
    end

    attr_reader :type, :max, :ox, :oy

    def dispose
      @sprites.each { |sprite| sprite.dispose }
      @rain_bitmap.dispose
      @storm_bitmap.dispose
      @snow_bitmap.dispose
    end

    def type=(type)
      return if @type == type
      @type = type
      bitmap = case @type
               when 1 then @rain_bitmap
               when 2 then @storm_bitmap
               when 3 then @snow_bitmap
               end
      _rgss_each_sprite do |sprite, i|
        sprite.visible = (i <= @max)
        sprite.bitmap = bitmap
      end
    end

    def ox=(ox)
      return if @ox == ox
      @ox = ox
      @sprites.each { |sprite| sprite.ox = @ox }
    end

    def oy=(oy)
      return if @oy == oy
      @oy = oy
      @sprites.each { |sprite| sprite.oy = @oy }
    end

    def max=(max)
      return if @max == max
      @max = [[max, 0].max, SPRITE_COUNT].min
      _rgss_each_sprite { |sprite, i| sprite.visible = (i <= @max) }
    end

    # Fall one frame: each drop moves and fades, and one that has faded out or
    # left the screen is thrown back to a random spot above it.
    def update
      return if @type == 0
      1.upto(@max) do |i|
        sprite = @sprites[i]
        break if sprite.nil?
        case @type
        when 1
          sprite.x -= 2
          sprite.y += 16
          sprite.opacity -= 8
        when 2
          sprite.x -= 8
          sprite.y += 16
          sprite.opacity -= 12
        when 3
          sprite.x -= 2
          sprite.y += 8
          sprite.opacity -= 8
        end
        x = sprite.x - @ox
        y = sprite.y - @oy
        next unless sprite.opacity < 64 || x < -50 || x > 750 || y < -300 || y > 500
        sprite.x = rand(800) - 50 + @ox
        sprite.y = rand(800) - 200 + @oy
        sprite.opacity = 255
      end
    end

    # RGSS indexes the sprite array 1..40 while filling it 0..39, so slot 40 is
    # always nil and slot 0 is never shown. Kept — a game that sets `max` to 40
    # gets 39 drops in the real player too, and the sprite count is what a script
    # reading `max` back expects.
    def _rgss_each_sprite
      1.upto(SPRITE_COUNT) do |i|
        sprite = @sprites[i]
        yield(sprite, i) unless sprite.nil?
      end
    end
  end
end
