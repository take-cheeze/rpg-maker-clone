MRuby::Gem::Specification.new('mruby-rpg2k') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = ''

  add_dependency 'mruby-lcf'
  add_dependency 'mruby-rgss'

  # Core *-ext gems whose methods this gem's Ruby actually calls. They are in the
  # shared list in build_config.rb (rpg_maker_gems) so the full game build has
  # them, but the dependency belongs here too — see AGENTS.md: a per-gem build
  # only pulls the gem plus its declared dependencies, so an undeclared one is a
  # NoMethodError waiting for the first gem-level test.
  #   mruby-array-ext   Array#compact  (Show Choices' label list, the party
  #                     roster's initial members)
  #   mruby-numeric-ext Integer#zero?  (used across game.rb / main.rb)
  #   mruby-enum-ext    Enumerable#sort_by / each_with_object
  #   mruby-range-ext   Range#cover?   (Game::Shop#equip?, the special-item
  #                     type checks in game.rb / scene/item_menu.rb)
  add_dependency 'mruby-array-ext'
  add_dependency 'mruby-numeric-ext'
  add_dependency 'mruby-enum-ext'
  add_dependency 'mruby-range-ext'

  # RPG_RT's own F9 debug menu (Switch/Variable browser, the chipset
  # passability editor, the whole-map viewer) and the matching
  # --rpg2k_map_editor/--rpg2k_chipset_editor CLI dev tools are gated behind
  # RPG2k#test_play at every real call site (Scene::Map#try_open_debug_menu:
  # "return unless @parent.test_play") -- a released game never reaches any
  # of it. Measured by compiling mrblib with and without these three files
  # (real `mrbc -g`, see docs/adr/0097-rpg2k-debug-tools-trim.md): 18,259 of
  # the 413,612 bytes mruby-rpg2k's mrblib compiles to (iseq+pool+syms) --
  # code no player-facing psp/wio binary calls. Same `%w[psp wio]` grouping
  # mruby-rgss's own mrbgem.rake already uses (that gem's pthread linking):
  # this build's own name, not the host half of a cross build that also
  # produces mrbc alongside it.
  if %w[psp wio].include?(build.name)
    spec.rbfiles -= %W[
      #{dir}/mrblib/scene/debug_menu.rb
      #{dir}/mrblib/scene/chipset_editor.rb
      #{dir}/mrblib/scene/map_viewer.rb
    ]
  end

  # docs/adr/0108's own real attempt: mruby-rpg2k is a pure-Ruby gem (its own
  # src/rgss_ext.cxx is two empty gem_init/gem_final stubs -- everything real
  # is mrblib/*.rb), so in principle its entire compiled bytecode could live
  # on the SD card instead of the firmware, loaded once at boot via
  # mrb_load_irep_buf the same way ADR 0099's own smoke test loads
  # mruby-lcf's. RGSS_WIO_EXTERNAL_RPG2K, a no-op unless set, drops every one
  # of this gem's own rbfiles for *whichever* build it's set for (not just
  # wio -- a host build with it set is exactly how the ADR's own host-side
  # proof produces a "core + shared gems, no rpg2k Ruby" libmruby.a to load
  # a matching external .mrb into), superseding the narrower debug-tools/
  # battle trims above wherever it's active. Not the default: see the ADR
  # for why loading it back in on real wio hardware is the open, unresolved
  # half of this attempt.
  if ENV['RGSS_WIO_EXTERNAL_RPG2K']
    spec.rbfiles = []
  elsif build.name == 'wio'
    # A live fight's own bytecode -- Game::Battle (the headless combat model,
    # split into its own file for exactly this exclusion), Scene::Battle and
    # RPG2k3::Scene::Battle -- is 180,368 bytes on its own (docs/adr/0107's
    # own real measurement: three separate mrbc compiles, summed), a sixth of
    # the Wio Terminal's entire flash budget, for a feature most of any given
    # session never reaches (a save/load/menu-only play session, or this
    # port's own current boot-test firmware, which loads no game data and so
    # starts no fight at all). Unlike the debug-tools trim above, this is
    # *wio-only*, not psp -- PSP has real flash/storage headroom this board
    # does not, and dropping these files here does not yet come with any way
    # to get them back: no runtime loader reads them from the SD card the way
    # ADR 0007's still-unbuilt P3 asset-streaming work would need to, so a
    # wio build with this exclusion cannot actually start a fight today. This
    # trim exists to prove the split is real and measure its actual cost, not
    # to claim battle done as a wio feature -- see the ADR for what remains.
    spec.rbfiles -= %W[
      #{dir}/mrblib/game/battle.rb
      #{dir}/mrblib/scene/battle.rb
      #{dir}/mrblib/scene/battle_rpg2k3.rb
    ]
  end
end
