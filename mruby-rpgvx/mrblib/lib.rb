# RPG Maker VX / VX Ace runtime.
#
# VX (RGSS2) and VX Ace (RGSS3) are the two RGSS makers between XP and MV. They
# keep XP's shape — a `Game.ini`, a `Data/` folder of Ruby `Marshal` dumps and a
# bundled script bundle that *is* the engine — and change three things that
# matter to a player:
#
#   * the data extension (`.rvdata` / `.rvdata2`) and the record schema
#     (mrblib/rgss2_data.rb),
#   * the encrypted-archive name (`Game.rgss2a`, the same version-1 format as
#     XP's `.rgssad`; `Game.rgss3a`, the version-3 format) — both already
#     decoded by `RPGXP::RGSSAD`,
#   * the screen: 544x416 instead of XP's 640x480.
#
# This file is the boot shell: it detects which of the two editions a directory
# holds, loads the database through `RPGVX::RGSSData`, and — because a VX/VX Ace
# game ships its whole engine as Ruby — runs the project's own scripts through
# the shared RGSS script host when that is enabled. A reimplemented built-in
# title/map flow (what mruby-rpg2k and mruby-rpgxp do) is not built yet; until it
# is, a boot without the script host reports the pending runtime rather than
# showing a blank window. See docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md.
#
# Deliberately free of load-time RGSS references so the pure logic here (edition
# detection, path mapping) can be loaded and exercised under CRuby by
# scripts/rpgvx_testbed_check.rb.
class RPGVX
  # RPG Maker VX and VX Ace both render at 544x416 with 32px tiles. src/main.cxx
  # sizes the window to match when a VX project is detected and the size was not
  # overridden on the command line.
  WIDTH = 544
  HEIGHT = 416
  TILE = 32

  # The two editions, most recent first — detection order matters for a project
  # that carries both (an upgraded VX project keeps its old `.rvdata` files
  # beside the converted ones, and the editor treats it as VX Ace).
  #
  #   ext     - the Data/ file extension
  #   archive - the encrypted release archive that stands in for a loose Data/
  #   system  - the marker file identifying an unpacked project
  #   rgss    - the RGSS version the edition's scripts are written against
  EDITIONS = {
    vxace: {
      name: "RPG Maker VX Ace", ext: ".rvdata2", archive: "Game.rgss3a",
      system: "Data/System.rvdata2", rgss: 3
    },
    vx: {
      name: "RPG Maker VX", ext: ".rvdata", archive: "Game.rgss2a",
      system: "Data/System.rvdata", rgss: 2
    }
  }.freeze

  class << self
    # Pure predicate: given the set of project-relative files that exist, which
    # edition (if any) is this? Split out from `detect` so it can be exercised
    # without touching the filesystem (see mruby-rpgvx/test).
    def edition_for(present)
      EDITIONS.each do |edition, info|
        return edition if present.include?(info[:system]) ||
                          present.include?(info[:archive])
      end
      nil
    end

    # The edition of the project in `dir`, or nil when it is not a VX/VX Ace
    # project. A packed release ships no loose `Data/`, so the archive counts as
    # a marker in its own right — which is also the only way to tell a packed VX
    # release from a packed VX Ace one.
    def detect(dir = GAME_DIR)
      EDITIONS.each do |edition, info|
        return edition if File.exist?("#{dir}/#{info[:system]}") ||
                          File.exist?("#{dir}/#{info[:archive]}")
      end
      nil
    end

    def project?(dir = GAME_DIR)
      !detect(dir).nil?
    end

    def info(edition)
      EDITIONS[edition] || raise("unknown RPG Maker VX edition: #{edition.inspect}")
    end

    # The Data/ file extension of an edition (".rvdata" / ".rvdata2").
    def data_ext(edition)
      info(edition)[:ext]
    end

    def edition_name(edition)
      info(edition)[:name]
    end

    # False until the built-in title/map flow exists. The database layer and the
    # script host below are real; a game still cannot boot without one of them.
    def runtime_available?
      false
    end
  end

  def initialize(_args)
    @edition = self.class.detect(GAME_DIR)
    # Declare the screen the window was opened at (src/main.cxx sizes it to the
    # same numbers), so the scripts' `Graphics.width`/`height` — which VX's
    # camera and every window layout are computed from — report VX's resolution
    # rather than the RGSS default.
    RGSS::Graphics.resize_screen(WIDTH, HEIGHT)
    @db = RGSSData.new(GAME_DIR, @edition) if @edition
    @title = read_title
    # A VX/VX Ace project's engine *is* its script bundle, so the script host is
    # the only path that can currently run one. Off by default, like XP's.
    @use_script_host = @db && RPGXP::ScriptHost.enabled? && @db.scripts?
    setup_script_host_driver if @use_script_host
  rescue StandardError => e
    # A data problem must not crash the binary to a blank window; report it and
    # let #start fall through to the pending notice.
    $stderr.puts "[RGSS2] failed to load the #{maker_name} database: #{e.message}"
    @db = nil
  end

  attr_reader :db, :edition, :title

  # The edition's display name, for logs ("RPG Maker VX Ace").
  def maker_name
    @edition ? self.class.edition_name(@edition) : "RPG Maker VX"
  end

  # Native entry point. Report what was detected and loaded, then either drive
  # the project's own scripts (when the host is enabled) or report the pending
  # built-in runtime — mirroring how the MZ side reports its staged state.
  def start
    report_database
    if @host_fiber
      loop do
        main_loop
        break if @host_done
      end
    else
      warn_runtime_pending
    end
  rescue RGSS::Timeout
  end

  # One frame. Both the desktop loop above and the web per-frame callback
  # (src/main.cxx) call this.
  def main_loop
    return drive_script_host if @host_fiber
    # The host game has ended (its Main returned, or a script stopped it); the
    # web per-frame callback keeps calling this, so idle rather than reporting
    # the pending built-in flow for a game that just ran.
    return if @host_done
    warn_runtime_pending
  end

  private

  # Log the detected edition and a one-line summary of the loaded database. The
  # `[RGSS2-DB]` marker is what scripts/rpgvx_testbed_check.rb looks for when it
  # is pointed at a real project through the built binary.
  def report_database
    unless @db
      $stderr.puts "[RGSS2] no RPG Maker VX / VX Ace project found under #{GAME_DIR}"
      return
    end
    $stderr.puts "[RGSS2-DB] #{maker_name} #{@title.inspect}: " \
                 "#{@db.summary}#{@db.archived? ? " (packed archive)" : ""}"
  end

  # The window/log title: VX and VX Ace both keep it in the database
  # (`System#game_title`, which the editor also mirrors into Game.ini), so read
  # it there and fall back to the folder name.
  def read_title
    title = @db && @db.system && @db.system.game_title
    return title if title.is_a?(String) && !title.empty?
    File.basename(GAME_DIR)
  rescue StandardError => e
    $stderr.puts "[RGSS2] could not read the game title: #{e.message}"
    "RPG Maker VX"
  end

  # Build the driver Fiber for the bundled scripts, so their blocking main loop
  # advances one frame per `main_loop` call (the web build's per-frame callback
  # must get control back every frame). Shared with the XP runtime; see
  # docs/adr/0023-rpgxp-script-host-frame-driver.md.
  def setup_script_host_driver
    @host_fiber = RPGXP::ScriptHost.build_driver(@db)
  end

  # Advance the script host by one frame. When its Main returns the Fiber is
  # dead and the game is over; a failure logs and falls back to the pending
  # notice rather than crashing to a blank screen.
  def drive_script_host
    if @host_fiber.alive?
      @host_fiber.resume
    else
      @host_fiber = nil
      @host_done = true
    end
  rescue RGSS::Timeout, SystemExit
    # A clean end: the timeout guard fired, a script called `rgss_stop`, or one
    # called `exit`. End the game rather than treating it as a boot failure.
    @host_fiber = nil
    @host_done = true
  rescue StandardError => e
    $stderr.puts "[RGSS2] script host failed (#{e.class}: #{e.message})"
    @host_fiber = nil
    @host_done = true
  end

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[RGSS2] #{maker_name} support is under construction: the " \
                 "database (Data/*#{@edition ? self.class.data_ext(@edition) : ".rvdata"}, " \
                 "loose or inside an encrypted archive) loads, but the built-in " \
                 "title/map flow is not written yet. A project that ships its " \
                 "scripts can be driven by the RGSS script host instead " \
                 "(RGSS_SCRIPT_HOST=1). See " \
                 "docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md."
  end
end
