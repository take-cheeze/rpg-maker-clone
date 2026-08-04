MRuby::Gem::Specification.new('mruby-rpgvx') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RPG Maker VX / VX Ace (RGSS2 / RGSS3) runtime'

  # The VX side is layered on the XP runtime rather than duplicating it: the
  # encrypted-archive reader (RPGXP::RGSSAD, which already decodes VX's
  # `Game.rgss2a` and VX Ace's `Game.rgss3a`), the RGSS script host and the
  # top-level Table/Color/Tone/Rect bindings Marshal resolves through are all
  # shared. Declaring the dependency also fixes the load order: mruby-rpgxp's
  # `RPG::*` schema is evaluated first, and rgss2_data.rb then reopens those
  # classes with the RGSS2/RGSS3 fields (see the header of that file).
  add_dependency 'mruby-rpgxp'
  # Data/*.rvdata(2) are Ruby Marshal dumps, like XP's .rxdata.
  add_dependency 'mruby-marshal'
  add_dependency 'mruby-io'
  # Array#compact, used to count the 1-based (nil at index 0) database tables.
  add_dependency 'mruby-array-ext'

  # Load order matters: lib.rb defines the RPGVX class and its WIDTH/HEIGHT/TILE
  # constants, which the data sources read at class-body evaluation time. Set the
  # order explicitly rather than relying on the default alphabetical glob.
  spec.rbfiles = %w[lib rgss2_data rgss_data].map do |name|
    "#{dir}/mrblib/#{name}.rb"
  end
end
