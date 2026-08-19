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
#   * **A missing asset yields a blank 32x32 bitmap and a warning**, where RGSS
#     raises. A game whose RTP is not installed must not die on its first
#     graphic, and with no second engine to fall back to (ADR 0030) a raise here
#     would end the run.
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

# Ruby's own `Module#private_method_defined?` / `#protected_method_defined?` /
# `#public_method_defined?`, which this mruby build does not ship as such —
# unlike `Errno`/`String#encode` above, this one is not a stub: mruby-metaprog
# already provides `private_instance_methods`/`protected_instance_methods`/
# `public_instance_methods` (used by `Module#instance_methods` itself), so the
# visibility-filtered membership check these three ask for is answerable
# exactly, just not under this name. A real project's scripts reach for these
# in visibility-aware `method_missing`/introspection helpers — e.g. an error
# logger's dump of "was this rescue handler overridden privately" — genuinely
# checking, not merely tolerating being asked.
unless Module.method_defined?(:private_method_defined?)
  class Module
    def private_method_defined?(sym, inherit = true)
      private_instance_methods(inherit).include?(sym.to_sym)
    end

    def protected_method_defined?(sym, inherit = true)
      protected_instance_methods(inherit).include?(sym.to_sym)
    end

    def public_method_defined?(sym, inherit = true)
      public_instance_methods(inherit).include?(sym.to_sym)
    end
  end
end

# Ruby's own bare (argument-less) `module_function` — CRuby's "declaration
# mode", where every `def` that follows in the same scope becomes both a
# private instance method and a public singleton method. This mruby version
# ships the explicit-argument form (`module_function :name`, converting an
# already-defined method — 3rd/mruby/src/class.c's `mrb_mod_module_function`)
# but the bare form is a documented no-op there: `if (argc == 0) { /* set
# MODFUNC SCOPE if implemented */ return mod; }`. A module built entirely
# under a bare declaration — e.g. a bundled error-log utility whose public
# entry point is only ever reachable as `TKG::ErrorLog.save(...)` — silently
# defines no singleton methods at all, so the first call raises NoMethodError
# and ends the whole script host.
#
# Reimplemented here without touching the vendored mruby core: mruby's
# `method_added` hook *does* fire reliably for every `def` (the VM checks
# whether it is still the built-in no-op before bothering to call it — see
# `mrb_method_added` — so overriding it here has no cost for classes that
# never trigger it), and the explicit-argument form already promotes an
# existing method correctly. So `module_function` with no arguments just
# flips a per-module flag, and `method_added` — called after the method is
# already registered — hands the newly-added name to the real
# explicit-argument path to promote it, exactly mirroring what CRuby does in
# one step. `private`/`public` with no arguments (which this mruby build
# implements correctly, via the same kind of scope tracking CRuby uses —
# `find_visibility_scope` in class.c) end the declaration the same way they
# do in CRuby, so a script that returns to normal instance methods after its
# module-function block is not stuck being module_function forever.
#
# What this does not reproduce: CRuby's version is a true lexical-scope
# state (reset on leaving the enclosing `module`/`class` body), where this is
# a per-module flag that persists until explicitly turned off. A script that
# reopens the *same* module later in the bundle, defining ordinary instance
# methods without an intervening bare `private`, would see those wrongly
# promoted too — a real gap, but a narrow one: RGSS scripts overwhelmingly
# write a `module_function` block as one contiguous run, the way the bundled
# utility this was found against does.
unless Module.method_defined?(:__mrb_native_module_function)
  class Module
    alias_method :__mrb_native_module_function, :module_function

    def module_function(*syms)
      if syms.empty?
        @__mrb_module_function_scope = true
        self
      else
        @__mrb_module_function_scope = false
        __mrb_native_module_function(*syms)
      end
    end

    alias_method :__mrb_native_private, :private
    def private(*syms)
      @__mrb_module_function_scope = false if syms.empty?
      __mrb_native_private(*syms)
    end

    alias_method :__mrb_native_public, :public
    def public(*syms)
      @__mrb_module_function_scope = false if syms.empty?
      __mrb_native_public(*syms)
    end

    def method_added(name)
      __mrb_native_module_function(name) if @__mrb_module_function_scope
    end

    # `module_function`/`private`/`public`/`method_added` are all private
    # methods on `Module` in real Ruby (so e.g. `some_mod.private(:x)` from
    # outside does not work); `def` here defaulted the overrides above to
    # public, so restore that. This call goes through the override (explicit
    # symbols, so it forwards straight to `__mrb_native_private`), which sets
    # real visibility either way — the fix applies regardless of which
    # `private` answers it.
    private :module_function, :private, :public, :method_added
  end
end

# Ruby's own `Time#strftime`, which this mruby build's Time (mruby-time) does
# not expose — it uses the C library's strftime() internally for `#to_s`, but
# never binds a Ruby-level method taking a format string, so any script that
# formats a timestamp for a log line or a save filename (a very ordinary
# thing to do — e.g. the same bundled error-log utility used above,
# `"Log/error_log" + Time.now.strftime("%Y%m%d%H%M%S") + ".txt"`) hits
# NoMethodError. Implemented in pure Ruby over the component accessors Time
# already exposes (`year`/`mon`/`day`/`hour`/`min`/`sec`/`wday`/`yday`/
# `usec`/`utc_offset`), covering the directives real scripts actually use —
# the common date/time/zero-padded-numeric set, not the full CRuby spec
# (no `%V`/`%U`/`%W` week-of-year, no locale-dependent forms, no field-width
# modifiers). An unrecognised directive passes through literally rather than
# raising, matching how a real `strftime("%Q")` degrades on an unknown
# specifier being kinder than crashing the whole script host over a log
# timestamp.
unless Time.method_defined?(:strftime)
  class Time
    MONTHNAMES = [nil, "January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November",
                  "December"].freeze
    ABBR_MONTHNAMES = MONTHNAMES.map { |m| m && m[0, 3] }.freeze
    DAYNAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday
                  Saturday].freeze
    ABBR_DAYNAMES = DAYNAMES.map { |d| d[0, 3] }.freeze

    def strftime(fmt)
      out = +""
      i = 0
      while i < fmt.length
        c = fmt[i]
        if c != "%" || i == fmt.length - 1
          out << c
          i += 1
          next
        end
        spec = fmt[i + 1]
        i += 2
        case spec
        when "Y" then out << year.to_s
        when "y" then out << format("%02d", year % 100)
        when "m" then out << format("%02d", mon)
        when "d" then out << format("%02d", day)
        when "e" then out << format("%2d", day)
        when "H" then out << format("%02d", hour)
        when "I" then out << format("%02d", ((hour % 12).zero? ? 12 : hour % 12))
        when "M" then out << format("%02d", min)
        when "S" then out << format("%02d", sec)
        when "L" then out << format("%03d", usec / 1000)
        when "N" then out << format("%09d", usec * 1000)
        when "j" then out << format("%03d", yday)
        when "p" then out << (hour < 12 ? "AM" : "PM")
        when "P" then out << (hour < 12 ? "am" : "pm")
        when "A" then out << DAYNAMES[wday]
        when "a" then out << ABBR_DAYNAMES[wday]
        when "B" then out << MONTHNAMES[mon]
        when "b", "h" then out << ABBR_MONTHNAMES[mon]
        when "z"
          off = utc_offset
          sign = off < 0 ? "-" : "+"
          off = off.abs
          out << format("%s%02d%02d", sign, off / 3600, (off / 60) % 60)
        when "Z" then out << zone.to_s
        when "%" then out << "%"
        when "n" then out << "\n"
        when "t" then out << "\t"
        when "F" then out << strftime("%Y-%m-%d")
        when "T", "X" then out << strftime("%H:%M:%S")
        when "D", "x" then out << strftime("%m/%d/%y")
        when "s" then out << to_i.to_s
        else
          # Unrecognised: pass the directive through literally rather than
          # raising or silently dropping it, so the mistake is visible in the
          # output instead of ending the script host.
          out << "%" << spec.to_s
        end
      end
      out
    end
  end
end

# Ruby's own `String#encode`, which this mruby build does not ship (no
# mruby-encoding gem is vendored or configured — mruby strings carry no
# per-instance encoding metadata at all). A Japanese project's scripts
# routinely transcode a string at a Windows API boundary, e.g. CACAO's widely
# bundled 画像保存 utility script binds a window title with
# `load_data(...).game_title.encode('SHIFT_JIS')` before passing it to a (here
# already-inert, see `Win32API` below) `FindWindow` call. Real transcoding
# needs conversion tables this build does not have, but nothing in this engine
# — UTF-8 throughout — ever depends on that boundary being correct, so this
# degrades the same way `Win32API#call` does: warn once, then answer the
# receiver unchanged rather than raise. A script that reads the *result* back
# as authentically Shift_JIS bytes (rather than just handing it to a Win32
# call this host cannot make anyway) would see the wrong content, but a
# NoMethodError here fails the whole script host over a boundary the game
# never gets to observe.
unless String.method_defined?(:encode)
  class String
    def encode(*)
      RGSS.warn_stub("String#encode")
      self
    end
  end
end

# `Dir.glob`, which the vendored `mruby-dir` gem (3rd/mruby/mrbgems/mruby-dir)
# never implements at any layer — its mrblib only supplies #each, #each_child,
# .foreach, .open and .chdir; its C HAL only opendir/readdir/mkdir/rmdir; no
# pattern matching anywhere. `Dir` is only present at all here because
# build_config.rb's `enable_test` pulls it in as a test-suite dependency of the
# host build, incidentally linking it into the shared game binary too — a real
# project never opts into it, but several bundled community scripts assume the
# full `Dir` a real Ruby install has. The stock RPG Maker VX Ace `DataManager`
# checks `!Dir.glob('Save0*.rvdata2').empty?` to decide whether to draw
# "Continue" on the title screen, `Game_System` globs a shared options file the
# same way, and released games routinely add a `Dir.glob('Game.rgss3a').empty?`
# check to tell a packed release apart from an unpacked project (e.g. to
# disable a test-mode menu) — none of that is optional or RTP-shaped, so
# `NoMethodError` here fails the whole script host before a single frame draws.
#
# Implemented over `Dir.entries` (which the HAL does supply) and a glob ->
# Regexp translator covering what these scripts actually write: literal
# names, `*` (any run of characters, one path component), `?` (one character)
# and `[...]` character classes — not the full glob spec (no `**`, brace
# expansion, or flags). A pattern is split on `/` and walked one directory
# level at a time so a prefix like `Data/Map[0-9]*[0-9].rvdata2` only lists
# `Data/`'s own entries, not every subdirectory the way a single flattened
# regex over the whole path would. Dotfiles are excluded unless the pattern's
# own component starts with a literal `.`, matching Ruby's default.
unless Dir.respond_to?(:glob)
  class Dir
    class << self
      private

      def __rgss_glob_translate(part)
        out = +"\\A"
        i = 0
        while i < part.length
          c = part[i]
          case c
          when "*"
            out << ".*"
          when "?"
            out << "."
          when "["
            close = part.index("]", i + 1)
            if close
              out << part[i..close]
              i = close
            else
              out << "\\["
            end
          else
            out << Regexp.escape(c)
          end
          i += 1
        end
        out << "\\z"
        Regexp.new(out)
      end

      def __rgss_glob_walk(base, parts)
        part = parts[0]
        rest = parts[1..-1]
        dir = base.empty? ? "." : base
        return [] unless FileTest.directory?(dir)

        if part =~ /[*?\[]/
          re = __rgss_glob_translate(part)
          names = Dir.entries(dir).select do |name|
            next false if name == "." || name == ".."
            next false if name.start_with?(".") && !part.start_with?(".")
            re.match?(name)
          end.sort
        else
          names = Dir.entries(dir).include?(part) ? [part] : []
        end

        if rest.empty?
          names.map { |name| base.empty? ? name : "#{base}/#{name}" }
        else
          # Not `flat_map`: mruby-array-ext does not carry it, and neither
          # does the Enumerable mixin reach Array's own natively-implemented
          # methods in this build.
          result = []
          names.each do |name|
            result.concat(__rgss_glob_walk(base.empty? ? name : "#{base}/#{name}", rest))
          end
          result
        end
      end
    end

    def self.glob(pattern, flags = 0, &block)
      if pattern.is_a?(Array)
        result = []
        pattern.each { |p| result.concat(glob(p, flags)) }
        return result
      end

      results = __rgss_glob_walk("", pattern.split("/")).sort
      if block
        results.each(&block)
        nil
      else
        results
      end
    end
  end
end

# RGSS's Win32API: a general FFI mechanism for calling arbitrary Win32 DLL
# entry points by name, which a project routinely uses for one *optional*
# Windows-only feature — e.g. CACAO's widely bundled 画像保存
# (Bitmap#save/Graphics.save_screen) utility script binds
# MultiByteToWideChar/FindWindow/BitBlt/... at its top level, unconditionally,
# just by being included in the project.
#
# There is no real Win32 to call into here (this engine also targets Linux,
# the PSP and wasm), and a script that merely *binds* a function is not
# choosing to use it yet — raising at `Win32API.new` would fail the whole
# script host over a feature the game may never invoke, exactly the class of
# unnecessary death this file's `RPG::Cache` fallback avoids for a missing
# asset. So construction always succeeds, and `#call` — the point an actual
# Windows API call would happen — warns once per (dllname, funcname) pair and
# answers 0, `Win32API#call`'s own return type: whatever Windows-only feature
# it drove (screenshot saving, a custom window border, ...) silently does
# nothing, same as a project shipping no RTP art.
class Win32API
  def initialize(dllname, funcname, import = nil, export = nil)
    @dllname = dllname
    @funcname = funcname
  end

  def call(*args)
    RGSS.warn_stub("Win32API #{@dllname}.#{@funcname}")
    0
  end
end unless Object.const_defined?(:Win32API)

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
      hued(path, hue, bitmap)
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

    # A hue-rotated copy, cached under its own key — RGSS's own
    # `@cache[key] = @cache[path].clone; @cache[key].hue_change(hue)`, so the
    # file is decoded once however many hues a game asks for. `base` is the hue-0
    # bitmap already in the cache; `RGSS::Bitmap#initialize_copy` copies its
    # pixels, so rotating the copy leaves the cached original alone.
    def self.hued(path, hue, base)
      key = "#{path}\t#{hue}"
      cached = @cache[key]
      return cached unless cached.nil? || cached.disposed?
      bitmap = base.clone
      bitmap.hue_change(hue)
      @cache[key] = bitmap
    end

    # Load one file, or report it and let the caller stand in. RGSS raises here;
    # a game whose RTP is missing would then die on its first graphic, so the
    # failure is reported once per path (the cache means one attempt each) and the
    # boot carries on.
    def self.load_file(path)
      RGSS::Bitmap.new(path)
    rescue RGSS::Bitmap::LoadError => e
      # The loader's own reason -- a decoder's complaint, or which of the search
      # roots came up empty. Taken off the exception rather than out of its
      # message, which spells the path out again in front of it.
      $stderr.puts "[RGSS] RPG::Cache: #{path} did not load (#{e.reason}); " \
                   "using a blank bitmap"
      nil
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
