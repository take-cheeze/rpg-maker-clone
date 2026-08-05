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
  add_dependency 'mruby-array-ext'
  add_dependency 'mruby-numeric-ext'
  add_dependency 'mruby-enum-ext'
end
